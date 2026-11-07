# Metrics operations

Syrus exposes Prometheus metrics from `GET /metrics`. By default the endpoint
requires the admin API Bearer token. Set `SYRUS_METRICS_PUBLIC=1` only when the
deployment deliberately places an unauthenticated scrape endpoint behind an
appropriate network boundary.

`GET /readyz` is the readiness contract. It reports whether the process can
serve traffic and includes failures from required operational dependencies.
Prometheus alert rules are maintained in
`config/prometheus/syrus-alert-rules.yml`.

## Metric families

The endpoint includes queue depth and latency, product usage, landing and Run
throughput, worker and admission state, fleet health, resilience events,
maintenance, repository-content reads, and frontend event amplification.
Plugin-owned metrics appear only while their plugin is enabled.

Do not sum gauges or counters that every web process exports from the same
database snapshot. The safe default for those series is `max by (...)`; the
architecture reference identifies the exceptional cluster-aggregated series.

For metric definitions, sampling, cursor mechanics, cardinality rules, and the
declaration DSL, see [Metrics architecture](../architecture/metrics.md).

Return to the [operations index](README.md).
