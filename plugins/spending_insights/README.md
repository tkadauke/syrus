# Spending Insights

Spending Insights adds a sidebar page for understanding agent spend across Syrus. It rolls costs up by epic, repository, user, provider, and workflow trigger so operators can see where automation budget is going.

Use it on instances where cost visibility matters. It reads existing accounting data and does not change scheduling, grading, or job behavior.

## What It Adds

- A primary sidebar page for spend summaries.
- Cost rollups by epic, repository, user, provider, and trigger kind.
- UI code and localization for spend inspection.

## When To Enable

Enable Spending Insights when operators need ongoing visibility into automation cost. It is safe to leave enabled on most production instances.

## Operational Notes

The plugin reports recorded spend data. It does not enforce budgets or pause work by itself.

## Metrics

While enabled, exports `syrus_spending_insights_run_cost_usd_total{provider,trigger_kind}` (a cumulative
counter of `Run#cost_usd`) to `/metrics`, so a cost blowup is alertable rather than only visible on this
page. See `docs/syrus_docs/spending_insights.md` for how it is sampled.
