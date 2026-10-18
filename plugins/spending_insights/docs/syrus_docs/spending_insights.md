# Spending Insights

Spending Insights is disabled by default. When enabled from **Admin → Plugins**, it adds a sidebar page rolling up agent spend by epic, repository, user, provider, and
workflow trigger kind. It reads completed Run accounting (`Run#cost_usd` at `Run#finished_at`) and the
per-turn chat spend ledger (`ChatSpendEntry`)
and does not change scheduling, grading, or job behavior.

Run costs appear in the window and daily bucket in which the Run completed. Cost-bearing Runs without a
completion timestamp are excluded until they finish. Chat costs are recorded per charged turn, so an old
chat's new spend appears on the date that the turn completed. Historical cumulative chat cost from before the
ledger existed is intentionally not assigned to a fabricated date.

The selected date window controls the trend, breakdowns, and top Runs. The
"This week", "This month", and "Lifetime" summaries use those calendar
periods independently of the selected window while retaining applicable
user, repository, Epic, provider, and trigger filters. Lifetime includes both
workflow and chat costs. CLI `--since` and `--until` flags may be used together
or independently; a lone flag creates an open-ended date filter.

## Metrics

While enabled, exports one Prometheus counter to `/metrics` (see `config/syrus_docs/metrics.md`):

| Metric | Meaning |
|---|---|
| `syrus_spending_insights_run_cost_usd_total{provider,trigger_kind}` | Cumulative `Run#cost_usd`, tagged by agent provider and workflow trigger kind |

Cost visibility on `/insights/spending` is request-computed and does not need this metric. The metric exists
so a cost blowup shows up on an existing dashboard/alerting pipeline instead of requiring someone to open the
page and notice.

**Sampling.** A Run's cost is finalized on whichever worker process ran its agent invocation, but `/metrics`
is served by the web role only. `SpendingInsights::MetricsSampler` needs cursor-based cumulative logic (not a
plain aggregate value), so it registers as a full sampler class via the manifest's
`metrics do ... sampler MetricsSampler end` (see `Syrus::PluginApi::Definition#metrics`). `#sample!` runs on
the shared control-plane tick (`SampleGlobalMetricsJob`, the same tick core samplers use -- no plugin-owned
`tick_interval`) and folds every Run that finished with a recorded cost since the last tick into a cumulative,
cache-mediated total -- the same cursor pattern `Metrics::LandingSampler` uses for `syrus_runs_total`.
`#refresh_gauges!`, called from that same shared registry on the `/metrics` scrape path, reconciles this
process's counter to that cached total.

**Disabled means absent, not zero.** Like every plugin metric, this follows `while_enabled` semantics: a
disabled Spending Insights plugin declares no metric at all, so the series disappears from `/metrics` rather
than freezing at its last value or reporting `0`.

### Metrics Dashboard tab

When the `metrics_dashboard` plugin is also enabled, Spending Insights contributes its own "Spending
Insights" tab there (`SpendingInsights::MetricsDashboardTabs`, registered under metrics_dashboard's hosted
`"metrics_dashboard:tab"` point -- see `plugins/metrics_dashboard/docs/syrus_docs/metrics_dashboard.md`), with
one panel per breakdown of the cost counter above: `run_cost_by_provider` and `run_cost_by_trigger_kind`. The
tab is absent, not empty, whenever either plugin is disabled.
