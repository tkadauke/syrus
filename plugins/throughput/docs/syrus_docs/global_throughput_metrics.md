# Global Throughput Metrics (Prometheus)

This is a different thing from `repository_throughput_metrics.md`. That document describes
`Throughput::MetricContract`: a per-repository contract computed fresh from durable rows on every API
request. This document describes two install-wide Prometheus counters the plugin exports to `/metrics`
(see `config/syrus_docs/metrics.md`) while enabled:

| Metric | Meaning |
|---|---|
| `syrus_throughput_landing_units_total{unit_type}` | Successful landing attempts. `unit_type` is `auto_merge` or `merge_train` -- one attempt counts as one unit regardless of how many Jobs it lands. |
| `syrus_throughput_jobs_landed_total` | Jobs landed via a successful landing attempt. A `merge_train` unit counts every member Job it landed; an `auto_merge` unit counts its one Job. |

These do not replace, recompute, or read from `Throughput::MetricContract`. They exist because that contract
is deliberately request-scoped to one repository and computed at read time -- the opposite of what `/metrics`
needs, which is a global total sampled off the request path (an endpoint that ran the contract's query shape
on every scrape would get slow at exactly the moment queue/DB pressure is the thing worth alerting on).

## Sampling

`Throughput::MetricsSampler` follows `Metrics::LandingSampler`'s shape and needs cursor-based cumulative
logic (not a plain aggregate value), so it registers as a full sampler class via the manifest's
`metrics do ... sampler MetricsSampler end` (see `Syrus::PluginApi::Definition#metrics`). `#sample!` runs on
the shared control-plane tick (`SampleGlobalMetricsJob`, the same tick core samplers use -- no plugin-owned
`tick_interval`) and folds every `auto_merge` Workflow or `merge_train` that finished successfully since the
last tick into a cumulative, cache-mediated total -- a cursor over `finished_at`, set exactly once per
attempt and never revised, so nothing is double-counted across ticks. `#refresh_gauges!`, called from that
same shared registry on the `/metrics` scrape path, reconciles this process's counters to that cached total
-- necessary because the Workflow/MergeTrain that finishes runs on a worker process, while `/metrics` is
served by the web role only.

## Disabled means absent, not zero

Like every plugin metric, both counters follow `while_enabled` semantics: disabling Throughput removes them
from `/metrics` entirely rather than freezing them at their last value or reporting `0`.
