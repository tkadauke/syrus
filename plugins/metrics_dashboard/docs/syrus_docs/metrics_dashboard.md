# Metrics Dashboard

Charts Syrus's own metrics inside the app, so a single-host install gets
operational history with no extra infrastructure to run. Off by default; enable
it from Admin -> Plugins.

## What it is for

Production "felt slow" on 2026-09-13 and the cause — a polling queue 2,715 jobs
deep with its oldest job 190 minutes old — took an hour of `kubectl` and ad-hoc
SQL to find, because nothing was recording it. This plugin is that hour turned
into a page.

It is **not** a query builder, and should not grow into one. It answers a fixed
set of questions:

- Is the queue keeping up? (oldest waiting job, depth, by queue)
- What is failing? (failed executions by job class, orphaned queue rows)
- Which features are used?

An install that needs arbitrary queries needs Prometheus, and `/metrics` is
already there for it — at which point this plugin can be turned off without
losing anything, because both read the same source.

## How it works

```
Syrus::Metrics registry --> GET /metrics --> Prometheus (optional, external)
                                        \
                                         -> MetricsDashboard::Recorder
                                              -> metrics_dashboard_samples
                                                   -> this page
```

The recorder consumes the **same exposition text** an external Prometheus would
scrape, rather than reading the registry directly. That is deliberate: the
built-in charts and a Grafana dashboard read one source, so they cannot disagree
about what a number means, and the plugin keeps working unchanged when core
declares new metrics.

It runs once a minute on the plugin tick (`tick_interval 1.minute`).
`PluginTickSchedulerJob` only ticks **enabled, healthy** plugins, which is what
makes disabling the plugin genuinely stop the recording rather than merely hide
the page.

Samples are one row per series per minute, retained 30 days, pruned hourly.
Fixed resolution and fixed retention are what keep this a rollup table rather
than a time-series database growing inside the primary database.

## What it can and cannot see

**Accurate: `syrus_global_*`.** Queue depth, oldest age, orphaned rows, plugin
enablement. These are sampled cluster-wide into the cache by
`SampleGlobalMetricsJob`, so every process renders the same numbers and the
recorder's copy is the truth.

**Partial: per-process counters.** `syrus_feature_used_total` is incremented in
whichever process served the request — currently web. The recorder runs on a
worker, so it records that worker's share, which is usually zero.

That gap is the cross-process capture that is not built yet (see
`docs/plans/prometheus-dashboard.md`): worker pods fork one process per queue
definition sharing no memory, and are not scraped. The feature-usage panel is
therefore present but thin until that lands, at which point it fills in with no
change to this plugin.

This is stated rather than hidden because a dashboard that quietly shows a
plausible-but-wrong zero is worse than one that shows nothing.

## Reading the panels

Series prefixed `syrus_global_` are **one cluster-wide fact**, rendered
identically by every process that serves `/metrics`. The payload reduces them
with `max`, never `sum` — summing them would multiply by the number of
recorders. `DashboardPayload::PANELS` encodes that per panel so nobody has to
remember the rule.

The header warns when recording has stopped or has never run, because "no data"
has two very different causes and an empty chart does not distinguish them.

## Access

Admin only. These are instance-wide operational numbers, not anything scoped to
the requesting user's work. When the plugin is disabled the endpoint answers
`plugin_disabled`.

## Uninstalling

`metrics_dashboard_samples` carries the plugin's name, so `Syrus::PluginPurge`
finds and drops it when the plugin is uninstalled. Disabling the plugin stops
recording but keeps the history, so re-enabling picks up where it left off.
