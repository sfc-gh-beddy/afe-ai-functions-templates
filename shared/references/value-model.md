# Value model: signal -> P&L lever

Use customer-supplied numbers only; mark every assumption. Never invent unit economics.

| Lever | Signal example | Formula | Inputs to ask for |
|---|---|---|---|
| OpEx: labor | % of contacts that are repeat / avoidable | avoidable volume x handle time x loaded cost/hr | volume, AHT, cost/hr |
| OpEx: manual processing | docs auto-extracted above confidence threshold | docs/month x minutes saved x cost/hr | doc volume, minutes per doc |
| OpEx: duplicate spend | duplicate vendors or records | duplicate vendors x avg duplicate spend | vendor count, spend |
| CapEx | failure precursors in maintenance notes | deferred replacements x unit capex | asset count, replacement cost |
| Revenue: retention | at-risk accounts with churn reason | at-risk ARR x expected save rate | ARR, historical save rate |
| Revenue: growth | upsell / cross-sell intent mentions | qualified intents x conversion x deal size | conversion, ACV |

Output: low / expected / high range, plus the AI Functions credit estimate, so ROI = value / Snowflake cost.
