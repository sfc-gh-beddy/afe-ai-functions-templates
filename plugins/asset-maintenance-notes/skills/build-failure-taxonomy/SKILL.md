---
name: build-failure-taxonomy
description: "Phase 2 of the asset-maintenance-notes build. Builds and pins the closed vocabulary the extractor is constrained to: component codes per asset class with assembly grouping, failure-mode codes defined as observed effect, and a site shorthand glossary mined from the corpus and confirmed by a maintenance lead. Sources: the sandbox taxonomy, the customer's own CMMS catalog profiles / failure hierarchies, or a customer-approved subset of an industry standard such as ISO 14224. Produces per-class enum arrays and prompt context for AI_COMPLETE structured output, a taxonomy version, and a gap-review loop for OTHER. Use when asked to define failure codes, clean up failure codes, build a component hierarchy, or map shorthand."
parent_skill: asset-maintenance-notes
---

# Build the failure taxonomy

The extractor is only as useful as the vocabulary it is constrained to. Without one, "DE brg",
"drive end bearing" and "motor bearing pump side" become three components and every downstream
count is fragmented. With a vocabulary that does not fit the fleet, everything lands in `OTHER`.

This phase produces four tables and one version string. It does not call any model except in the
optional gap-review step, which only proposes changes for a human to accept.

## Where the taxonomy comes from

Ask which applies; record `taxonomy.source`.

| Source | When | Notes |
|---|---|---|
| `sandbox` | Phase 1 was run | Load `SYNTH_TAXONOMY_COMPONENT` and `SYNTH_TAXONOMY_FAILURE_MODE`. Required for sandbox evaluation, because planted labels use these codes |
| `customer_tables` | The CMMS already has catalog profiles, object-part codes, damage codes, or a reliability team's failure hierarchy | Preferred for production. The codes exist; the problem is that they were not filled in. Reuse them so outputs join back to existing reporting |
| `iso14224_subset` | No usable customer hierarchy, and the customer wants an industry-standard structure | The customer selects and owns the subset. Do not reproduce a standard's code tables from memory -- have the customer supply the licensed content or their own adaptation |

Never invent a production taxonomy on the customer's behalf. A taxonomy is a reliability-engineering
decision with reporting consequences; the plugin structures and checks it.

## Design rules

1. **Per asset class.** Components are class-specific. A gearbox has no impeller. The extractor
   receives only its class's codes.
2. **Two levels for components.** `component_code` (the maintainable item) rolls up to
   `assembly_code` (the subunit). Evaluation scores both, and recurring-issue analysis often wants
   the assembly level.
3. **Failure mode is the observed effect.** "External leak", "high vibration", "fail to start".
   Not cause ("misalignment") and not action ("replaced"). Cause and action are free text fields on
   the signal.
4. **`NONE` and `OTHER` are explicit codes.** `NONE` pairs with `RULED_OUT` and `ACTION_ONLY`.
   `OTHER` is how the extractor says "a real finding outside the vocabulary" -- its share is a
   reported metric.
5. **Keep it under about twenty codes per class per field** where possible. Long enums are
   supported by the schema, but more choices with subtler boundaries raise confusion between
   neighbours; split very large classes rather than offering sixty components.
6. **Definitions are short and contrastive.** "WEAR: material loss without breakage" next to
   "BREAKDOWN: broken, seized, collapsed". Definitions go into the prompt; they are what resolves
   boundary cases.

## Step 1. Load the reference tables

Target names below are defaults; record actual names in `created_objects`.

```sql
CREATE OR REPLACE TABLE <DB>.<SCHEMA>.TAX_COMPONENT (
    taxonomy_version VARCHAR,
    asset_class      VARCHAR,
    component_code   VARCHAR,
    assembly_code    VARCHAR,
    component_name   VARCHAR,
    synonyms         VARCHAR,
    is_active        BOOLEAN
);

CREATE OR REPLACE TABLE <DB>.<SCHEMA>.TAX_FAILURE_MODE (
    taxonomy_version  VARCHAR,
    failure_mode_code VARCHAR,
    failure_mode_name VARCHAR,
    definition        VARCHAR,
    is_active         BOOLEAN
);
```

Sandbox load:

```sql
INSERT INTO <DB>.<SCHEMA>.TAX_COMPONENT
SELECT :taxonomy_version, asset_class, component_code, assembly_code, component_name, synonyms, TRUE
FROM <DB>.<SANDBOX_SCHEMA>.SYNTH_TAXONOMY_COMPONENT
UNION ALL
-- OTHER per class, so the enum always has an escape hatch.
SELECT DISTINCT :taxonomy_version, asset_class, 'OTHER', 'OTHER', 'Outside taxonomy', NULL, TRUE
FROM <DB>.<SANDBOX_SCHEMA>.SYNTH_TAXONOMY_COMPONENT;

INSERT INTO <DB>.<SCHEMA>.TAX_FAILURE_MODE
SELECT :taxonomy_version, failure_mode_code, failure_mode_name, definition, TRUE
FROM <DB>.<SANDBOX_SCHEMA>.SYNTH_TAXONOMY_FAILURE_MODE
UNION ALL
SELECT :taxonomy_version, 'OTHER', 'Other', 'A real failure that fits no listed mode', TRUE;
```

Customer load: map their catalog columns into the same shape. Write the mapping down in the session
and confirm it -- object-part codes frequently mix components and locations ("DE", "NDE") that need
combining before they are a component.

## Step 2. Coverage checks against the registry

```sql
-- Every asset class in the registry has components. Must return zero rows.
SELECT DISTINCT r.<class_col> AS asset_class
FROM <asset_registry> r
LEFT JOIN <DB>.<SCHEMA>.TAX_COMPONENT c
  ON c.asset_class = r.<class_col> AND c.taxonomy_version = :taxonomy_version
WHERE c.asset_class IS NULL;

-- Size per class.
SELECT asset_class, COUNT(*) AS components, COUNT(DISTINCT assembly_code) AS assemblies
FROM <DB>.<SCHEMA>.TAX_COMPONENT
WHERE taxonomy_version = :taxonomy_version
GROUP BY 1 ORDER BY 1;
```

An asset class with no taxonomy will be extracted with an empty enum, which is an error at call
time -- or, if someone "fixes" that by passing all codes, wrong-class answers.

## Step 3. Mine the shorthand glossary from the corpus

Abbreviations differ by site and trade. Find the frequent short tokens, then have a maintenance lead
expand them. Do not ship a generic glossary as the customer's.

```sql
WITH tokens AS (
    SELECT LOWER(t.value::STRING) AS token
    FROM <notes_table> n,
         LATERAL SPLIT_TO_TABLE(REGEXP_REPLACE(n.<text_col>, '[^A-Za-z0-9/#\\-]+', ' '), ' ') t
    WHERE LENGTH(t.value) BETWEEN 2 AND 5
)
SELECT token, COUNT(*) AS occurrences
FROM tokens
WHERE NOT REGEXP_LIKE(token, '^[0-9.\\-]+$')
GROUP BY 1
HAVING COUNT(*) >= 20
ORDER BY 2 DESC
LIMIT 200;
```

Show the list; ask the maintenance lead to expand the ones that are domain shorthand, and to flag
ambiguous ones with both readings and the disambiguating context. Store:

```sql
CREATE OR REPLACE TABLE <DB>.<SCHEMA>.TAX_GLOSSARY (
    taxonomy_version VARCHAR,
    asset_class      VARCHAR,     -- NULL = all classes
    term             VARCHAR,
    expansion        VARCHAR,
    ambiguity_note   VARCHAR,     -- e.g. 'o/h = overhaul on WOs, overhead on electrical'
    confirmed_by     VARCHAR      -- role, not a person's name
);
```

For the sandbox, a starter glossary consistent with the templates:

```sql
INSERT INTO <DB>.<SCHEMA>.TAX_GLOSSARY (taxonomy_version, asset_class, term, expansion, ambiguity_note, confirmed_by) VALUES
  (:taxonomy_version, NULL,              'brg',  'bearing',                      NULL, 'sandbox'),
  (:taxonomy_version, NULL,              'brgs', 'bearings',                     NULL, 'sandbox'),
  (:taxonomy_version, NULL,              'vib',  'vibration',                    NULL, 'sandbox'),
  (:taxonomy_version, NULL,              'DE',   'drive end',                    NULL, 'sandbox'),
  (:taxonomy_version, NULL,              'NDE',  'non-drive end',                NULL, 'sandbox'),
  (:taxonomy_version, NULL,              'o/c',  'on call / callout',            NULL, 'sandbox'),
  (:taxonomy_version, NULL,              'o/h',  'overhaul',                     'Could mean overhead in electrical notes', 'sandbox'),
  (:taxonomy_version, NULL,              'u/s',  'unserviceable',                NULL, 'sandbox'),
  (:taxonomy_version, NULL,              'nff',  'no fault found',               NULL, 'sandbox'),
  (:taxonomy_version, NULL,              'nil',  'none',                         NULL, 'sandbox'),
  (:taxonomy_version, NULL,              'disch','discharge',                    NULL, 'sandbox'),
  (:taxonomy_version, NULL,              'LOTO', 'lock out tag out',             NULL, 'sandbox'),
  (:taxonomy_version, NULL,              'VFD',  'variable frequency drive',     NULL, 'sandbox'),
  (:taxonomy_version, NULL,              'IR',   'insulation resistance',        NULL, 'sandbox'),
  (:taxonomy_version, 'AIR_COMPRESSOR',  'sep',  'oil separator',                NULL, 'sandbox'),
  (:taxonomy_version, 'GEARBOX',         'mag plug', 'magnetic drain plug',      NULL, 'sandbox');
```

## Step 4. Per-class prompt context and enum arrays

Precompute what the extractor needs per class so the prompt and the schema are built from the same
rows (one source, no drift between what the prompt describes and what the enum allows).

```sql
CREATE OR REPLACE TABLE <DB>.<SCHEMA>.TAX_CLASS_CONTEXT AS
WITH comp AS (
    SELECT asset_class,
           ARRAY_AGG(component_code) WITHIN GROUP (ORDER BY component_code) AS component_enum,
           LISTAGG(component_code || ' (' || assembly_code || '): ' || component_name
                   || COALESCE(' -- also written as: ' || synonyms, ''), '\n')
             WITHIN GROUP (ORDER BY component_code) AS component_text
    FROM <DB>.<SCHEMA>.TAX_COMPONENT
    WHERE taxonomy_version = :taxonomy_version AND is_active
    GROUP BY 1
), modes AS (
    SELECT ARRAY_AGG(failure_mode_code) WITHIN GROUP (ORDER BY failure_mode_code) AS mode_enum,
           LISTAGG(failure_mode_code || ': ' || definition, '\n')
             WITHIN GROUP (ORDER BY failure_mode_code) AS mode_text
    FROM <DB>.<SCHEMA>.TAX_FAILURE_MODE
    WHERE taxonomy_version = :taxonomy_version AND is_active
), gloss AS (
    SELECT c.asset_class,
           LISTAGG(g.term || ' = ' || g.expansion || COALESCE(' (' || g.ambiguity_note || ')', ''), '\n')
             WITHIN GROUP (ORDER BY g.term) AS glossary_text
    FROM comp c
    JOIN <DB>.<SCHEMA>.TAX_GLOSSARY g
      ON g.taxonomy_version = :taxonomy_version
     AND (g.asset_class IS NULL OR g.asset_class = c.asset_class)
    GROUP BY 1
)
SELECT :taxonomy_version AS taxonomy_version,
       c.asset_class, c.component_enum, c.component_text,
       m.mode_enum, m.mode_text,
       COALESCE(g.glossary_text, '') AS glossary_text,
       SHA2(c.component_text || m.mode_text || COALESCE(g.glossary_text, ''), 256) AS taxonomy_hash
FROM comp c CROSS JOIN modes m
LEFT JOIN gloss g ON g.asset_class = c.asset_class;
```

`taxonomy_hash` is persisted on every signal so a silent edit to a definition is detectable even if
nobody bumped `taxonomy.version`.

### Why the enum cannot simply be pasted into a static schema

`response_format` is an object literal or expression per call. Building it per row from
`component_enum` keeps it in sync with the table; `extract-failure-signals` shows the construction
with `OBJECT_CONSTRUCT` and the per-class arrays. Hard-coding enum lists into SQL text creates a
second copy of the taxonomy that will drift.

## Step 5. Gap review loop (after Phase 3, repeatable)

After a first extraction run, review `OTHER`:

```sql
SELECT s.asset_class, s.component_mention, COUNT(*) AS signals
FROM <DB>.<SCHEMA>.MAINT_SIGNALS s
WHERE s.taxonomy_version = :taxonomy_version
  AND s.component_code = 'OTHER' AND s.polarity = 'OBSERVED'
GROUP BY 1, 2
ORDER BY 3 DESC
LIMIT 50;
```

Optionally have a model **propose** mappings for the top mentions; a human accepts or rejects:

```sql
SELECT component_mention,
       AI_COMPLETE(
         model => :cluster_label_model,
         prompt => 'Asset class: ' || asset_class || '\nComponent vocabulary:\n' || component_text ||
                   '\n\nA technician wrote: "' || component_mention || '". Which code does this refer to? ' ||
                   'Answer NEW if none fit, and suggest a name. Respond in JSON.',
         model_parameters => {'temperature': 0},
         response_format => {'type': 'json', 'schema': {'type': 'object',
            'properties': {'proposed_code': {'type': 'string'}, 'is_new': {'type': 'boolean'},
                           'suggested_name': {'type': 'string'}, 'reason': {'type': 'string'}},
            'required': ['proposed_code', 'is_new']}}
       ) AS proposal
FROM (<top OTHER mentions joined to TAX_CLASS_CONTEXT>);
```

Accepted changes: add synonyms or codes, **bump `taxonomy.version`**, rebuild `TAX_CLASS_CONTEXT`,
and re-run extraction as a new experiment. Never edit codes in place under the same version.

## Gate verification

- component and assembly counts per class;
- failure-mode count, with `NONE` and `OTHER` present;
- registry coverage query returns zero rows;
- glossary row count and who confirmed it (role);
- `TAX_CLASS_CONTEXT` has one row per class with non-empty enums.

Write `taxonomy.version`, table names, and `phases.taxonomy: done` to `maintenance-project.yml`.
