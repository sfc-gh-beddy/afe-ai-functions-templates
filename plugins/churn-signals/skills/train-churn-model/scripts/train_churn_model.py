"""
Train, evaluate and register the churn model for the churn-signals play.

Trains three models on the same point-in-time feature table so the value
of the text features is measured rather than asserted:

    usage_only   account + usage features        (what most teams already have)
    text_only    extracted text features + account
    combined     everything                      (the model that is registered)

Optionally trains on ACCOUNT_FEATURES_LEAKY (sandbox only) to show what a
leaked model looks like. A leaky model is reported, never registered.

Usage:
    python train_churn_model.py \
        --connection <snow connection name> \
        --database CHURN_SIGNALS --schema PIPELINE \
        --model-name CHURN_MODEL --version V1 \
        --feature-version f1 --experiment-id exp_001 \
        [--leaky-demo]

Requires: snowflake-ml-python, snowflake-snowpark-python, xgboost, scikit-learn, pandas.
Runs the training locally or in a Snowflake Notebook; the sandbox feature
table is small. For large real tables, move training to a Container Runtime
notebook rather than pulling to pandas -- see SKILL.md.

All metrics are computed on the TEST split only, which is the latest renewals
by time (see 01_build_features.sql). Nothing here ever reads the answer key.
"""

from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timezone

import numpy as np
import pandas as pd
from sklearn.metrics import average_precision_score, brier_score_loss, roc_auc_score
from snowflake.snowpark import Session
from xgboost import XGBClassifier

ACCOUNT_FEATURES = ["ARR", "SEG_SMB", "SEG_MID_MARKET", "SEG_ENTERPRISE", "TENURE_DAYS"]
USAGE_FEATURES = ["UTIL_LAST3", "UTIL_PRIOR3", "UTIL_TREND", "LOGINS_RATIO", "USAGE_MONTHS_AVAILABLE"]
TEXT_FEATURES = [
    "N_INTERACTIONS", "N_RISK_INTERACTIONS",
    "N_REASON_PRICE_VALUE", "N_REASON_PRODUCT_GAP", "N_REASON_RELIABILITY", "N_REASON_SUPPORT",
    "N_REASON_ADOPTION", "N_REASON_COMPETITOR", "N_REASON_BUSINESS_CHANGE", "N_REASON_CHAMPION_LOSS",
    "N_INTENT_HIGH", "N_INTENT_MEDIUM", "MAX_INTENT_SCORE", "N_UNRESOLVED_RISK",
    "SHARE_NEGATIVE", "N_NEG_SUPPORT", "N_NEG_PRICE", "COMPETITOR_MENTIONED", "DAYS_SINCE_LAST_RISK",
]
FEATURE_SETS = {
    "usage_only": ACCOUNT_FEATURES + USAGE_FEATURES,
    "text_only": ACCOUNT_FEATURES + TEXT_FEATURES,
    "combined": ACCOUNT_FEATURES + USAGE_FEATURES + TEXT_FEATURES,
}
LEAKY_FEATURES = ACCOUNT_FEATURES + ["UTIL_LAST3", "N_RISK_INTERACTIONS", "N_INTENT_HIGH",
                                     "MAX_INTENT_SCORE", "CRM_STATUS_CHURNED"]

# Columns that must never be model inputs, whatever a future edit does.
FORBIDDEN = {"CHURNED", "SPLIT", "ACCOUNT_ID", "AS_OF_DATE", "RENEWAL_DATE", "MAX_TEXT_TS_USED",
             "MAX_USAGE_MONTH_USED", "BUILT_AT", "FEATURE_VERSION", "EXTRACTION_RUN_ID"}


def lift_table(y: np.ndarray, p: np.ndarray, bins: int = 10) -> pd.DataFrame:
    """Decile lift: churn rate in each score decile over the base rate. Decile 1 = highest risk."""
    df = pd.DataFrame({"y": y, "p": p}).sort_values("p", ascending=False).reset_index(drop=True)
    df["decile"] = (np.arange(len(df)) * bins // len(df)) + 1
    base = df["y"].mean()
    out = df.groupby("decile").agg(n=("y", "size"), churners=("y", "sum"), min_score=("p", "min"))
    out["churn_rate"] = out["churners"] / out["n"]
    out["lift"] = out["churn_rate"] / base if base > 0 else np.nan
    out["cum_capture"] = out["churners"].cumsum() / max(df["y"].sum(), 1)
    return out.reset_index()


def bootstrap_auc(y: np.ndarray, p: np.ndarray, n: int = 500, seed: int = 7) -> tuple[float, float]:
    """95% bootstrap interval. Small test sets make single-number AUC claims fragile."""
    rng = np.random.default_rng(seed)
    aucs = []
    for _ in range(n):
        idx = rng.integers(0, len(y), len(y))
        if y[idx].min() == y[idx].max():
            continue
        aucs.append(roc_auc_score(y[idx], p[idx]))
    if not aucs:
        return float("nan"), float("nan")
    return float(np.percentile(aucs, 2.5)), float(np.percentile(aucs, 97.5))


def fit(train: pd.DataFrame, features: list[str]) -> XGBClassifier:
    bad = FORBIDDEN.intersection(features)
    if bad:
        raise ValueError(f"Forbidden columns in feature list: {sorted(bad)}")
    y = train["CHURNED"].astype(int).to_numpy()
    pos, neg = int(y.sum()), int(len(y) - y.sum())
    if pos < 10:
        raise ValueError(f"Only {pos} churners in TRAIN. Increase the sandbox size or the label window "
                         "before trusting any metric.")
    model = XGBClassifier(
        n_estimators=300, max_depth=3, learning_rate=0.05, subsample=0.9, colsample_bytree=0.8,
        min_child_weight=2, reg_lambda=1.0, scale_pos_weight=neg / pos,
        eval_metric="auc", random_state=7, n_jobs=4,
    )
    model.fit(train[features].astype(float), y)
    return model


def evaluate(model: XGBClassifier, test: pd.DataFrame, features: list[str]) -> dict:
    y = test["CHURNED"].astype(int).to_numpy()
    p = model.predict_proba(test[features].astype(float))[:, 1]
    lo, hi = bootstrap_auc(y, p)
    lift = lift_table(y, p)
    top_decile = lift.iloc[0]
    return {
        "n_test": int(len(y)),
        "n_test_churners": int(y.sum()),
        "base_rate": round(float(y.mean()), 4),
        "auc": round(float(roc_auc_score(y, p)), 4),
        "auc_ci95": [round(lo, 4), round(hi, 4)],
        "pr_auc": round(float(average_precision_score(y, p)), 4),
        "brier": round(float(brier_score_loss(y, p)), 4),
        "top_decile_lift": round(float(top_decile["lift"]), 3),
        "top_decile_capture": round(float(top_decile["cum_capture"]), 3),
        "lift_table": lift.round(4).to_dict(orient="records"),
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--connection", required=True)
    ap.add_argument("--database", required=True)
    ap.add_argument("--schema", required=True)
    ap.add_argument("--model-name", default="CHURN_MODEL")
    ap.add_argument("--version", required=True, help="Registry version name, e.g. V1. Must be new.")
    ap.add_argument("--feature-version", required=True)
    ap.add_argument("--experiment-id", required=True)
    ap.add_argument("--leaky-demo", action="store_true", help="Sandbox only: also train on ACCOUNT_FEATURES_LEAKY.")
    ap.add_argument("--no-register", action="store_true")
    args = ap.parse_args()

    session = Session.builder.config("connection_name", args.connection).create()
    session.use_database(args.database)
    session.use_schema(args.schema)
    session.query_tag = f"churn-signals:{args.experiment_id}:train"

    df = session.table("ACCOUNT_FEATURES").filter("SPLIT IN ('TRAIN','TEST')").to_pandas()
    versions = df["FEATURE_VERSION"].unique().tolist()
    if versions != [args.feature_version]:
        raise SystemExit(f"ACCOUNT_FEATURES holds feature_version {versions}, expected [{args.feature_version}].")

    train, test = df[df["SPLIT"] == "TRAIN"], df[df["SPLIT"] == "TEST"]
    print(f"TRAIN rows={len(train)} churners={int(train['CHURNED'].sum())} | "
          f"TEST rows={len(test)} churners={int(test['CHURNED'].sum())}")

    results, models = {}, {}
    for name, feats in FEATURE_SETS.items():
        models[name] = fit(train, feats)
        results[name] = evaluate(models[name], test, feats)
        r = results[name]
        print(f"{name:11s} AUC={r['auc']} CI95={r['auc_ci95']} PR-AUC={r['pr_auc']} "
              f"top-decile lift={r['top_decile_lift']} capture={r['top_decile_capture']}")

    # Incremental value of text is the claim this play makes. Report it plainly,
    # including when it is small or negative.
    delta = round(results["combined"]["auc"] - results["usage_only"]["auc"], 4)
    print(f"AUC uplift from text features (combined - usage_only): {delta}")

    if results["combined"]["auc"] > 0.97:
        print("WARNING: combined AUC > 0.97. Treat as a leak until 02_leakage_audit.sql is clean "
              "and single-feature AUCs are reviewed.")

    leaky_result = None
    if args.leaky_demo:
        ldf = session.table("ACCOUNT_FEATURES_LEAKY").to_pandas()
        ltr, lte = ldf[ldf["SPLIT"] == "TRAIN"], ldf[ldf["SPLIT"] == "TEST"]
        FORBIDDEN.discard("CRM_STATUS_CHURNED")  # the demo deliberately uses it
        lm = fit(ltr, LEAKY_FEATURES)
        leaky_result = evaluate(lm, lte, LEAKY_FEATURES)
        print(f"LEAKY DEMO  AUC={leaky_result['auc']}  <- this is what leakage looks like. Not registered.")

    # Persist every experiment's metrics so runs accumulate and compare.
    run_at = datetime.now(timezone.utc).isoformat()
    rows = [{
        "EXPERIMENT_ID": args.experiment_id, "MODEL_NAME": args.model_name, "MODEL_VERSION": args.version,
        "FEATURE_VERSION": args.feature_version, "FEATURE_SET": k, "METRICS": json.dumps(v), "RUN_AT": run_at,
    } for k, v in results.items()]
    if leaky_result:
        rows.append({"EXPERIMENT_ID": args.experiment_id, "MODEL_NAME": args.model_name, "MODEL_VERSION": None,
                     "FEATURE_VERSION": args.feature_version, "FEATURE_SET": "LEAKY_DEMO",
                     "METRICS": json.dumps(leaky_result), "RUN_AT": run_at})
    session.sql("""CREATE TABLE IF NOT EXISTS MODEL_EXPERIMENTS (
        EXPERIMENT_ID VARCHAR, MODEL_NAME VARCHAR, MODEL_VERSION VARCHAR, FEATURE_VERSION VARCHAR,
        FEATURE_SET VARCHAR, METRICS VARIANT, RUN_AT TIMESTAMP_TZ)""").collect()
    session.create_dataframe(pd.DataFrame(rows)).write.mode("overwrite").save_as_table("MODEL_EXPERIMENTS_STAGING", table_type="temporary")
    session.sql("""INSERT INTO MODEL_EXPERIMENTS
        SELECT EXPERIMENT_ID, MODEL_NAME, MODEL_VERSION, FEATURE_VERSION, FEATURE_SET,
               PARSE_JSON(METRICS), RUN_AT::TIMESTAMP_TZ FROM MODEL_EXPERIMENTS_STAGING""").collect()
    session.sql("DROP TABLE MODEL_EXPERIMENTS_STAGING").collect()

    if args.no_register:
        return 0

    # Register the combined model with an EXPLICIT signature so the SQL output
    # keys are P_RETAINED / P_CHURN rather than inferred output_feature_N names.
    from snowflake.ml.model import model_signature
    from snowflake.ml.registry import Registry

    feats = FEATURE_SETS["combined"]
    model = models["combined"]
    X_sample = train[feats].astype(float).head(200)
    proba = pd.DataFrame(model.predict_proba(X_sample), columns=["P_RETAINED", "P_CHURN"])
    sig_proba = model_signature.infer_signature(input_data=X_sample, output_data=proba)

    reg = Registry(session=session, database_name=args.database, schema_name=args.schema)
    log_kwargs = dict(
        model_name=args.model_name,
        version_name=args.version,
        conda_dependencies=["xgboost", "scikit-learn"],
        signatures={"predict_proba": sig_proba},
        target_platforms=["WAREHOUSE"],
        comment=f"churn-signals combined model; feature_version={args.feature_version}; "
                f"experiment={args.experiment_id}",
    )
    # The docs describe sample_input_data and signatures as alternatives; it is
    # also the background data for explainability. Not verified whether every
    # snowflake-ml-python version accepts both, so fall back explicitly and say so.
    try:
        mv = reg.log_model(model, sample_input_data=X_sample, **log_kwargs)
    except Exception as exc:  # noqa: BLE001 - surface, then retry without background data
        print(f"log_model with sample_input_data failed ({exc}); retrying with signatures only. "
              "Explainability may then be unavailable for this version.")
        mv = reg.log_model(model, **log_kwargs)
    for k in ("auc", "auc_ci95", "pr_auc", "brier", "top_decile_lift", "top_decile_capture",
              "n_test", "n_test_churners"):
        mv.set_metric(f"test_{k}", results["combined"][k])
    mv.set_metric("auc_uplift_vs_usage_only", delta)
    mv.set_metric("feature_list", feats)
    print(f"Registered {args.model_name} {args.version}. Verify with: "
          f"SHOW FUNCTIONS IN MODEL {args.model_name} VERSION {args.version};")
    return 0


if __name__ == "__main__":
    sys.exit(main())
