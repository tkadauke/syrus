# Spending Insights

Spending Insights adds a sidebar page rolling up agent spend by epic, repository, user, provider, and
workflow trigger kind. It reads existing accounting data (`Run#cost_usd`, `ChatSession#cumulative_cost_usd`)
and does not change scheduling, grading, or job behavior.

## Metrics

While enabled, exports one Prometheus counter to `/metrics` (see `config/syrus_docs/metrics.md`):

| Metric | Meaning |
|---|---|
| `syrus_spending_insights_run_cost_usd_total{provider,trigger_kind}` | Cumulative `Run#cost_usd`, tagged by agent provider and workflow trigger kind |

Cost visibility on `/insights/spending` is request-computed and does not need this metric. The metric exists
so a cost blowup shows up on an existing dashboard/alerting pipeline instead of requiring someone to open the
page and notice.

**Sampling.** A Run's cost is finalized on whichever worker process ran its agent invocation, but `/metrics`
is served by the web role only. `SpendingInsights::MetricsSampler#sample!` runs on the plugin's own tick
(`tick_interval 1.minute`, driven by `SpendingInsights::Callbacks#on_tick`) and folds every Run that finished
with a recorded cost since the last tick into a cumulative, cache-mediated total -- the same cursor pattern
`Metrics::LandingSampler` uses for `syrus_runs_total`. `SpendingInsights::Callbacks#on_metrics_scrape`, called
from the `/metrics` scrape path, reconciles this process's counter to that cached total.

**Disabled means absent, not zero.** Like every plugin metric, this follows `while_enabled` semantics: a
disabled Spending Insights plugin declares no metric at all, so the series disappears from `/metrics` rather
than freezing at its last value or reporting `0`.
