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
set of questions, grouped into three tabs:

- **Queue & Throughput** — is the queue keeping up (oldest waiting job, depth,
  by queue), what is failing (failed executions by job class, orphaned queue
  rows), and is Syrus actually landing work (jobs landed, runs by state,
  landing queue depth, Solid Queue table size).
- **Workers & Fleet** — is the worker fleet keeping up (per-host CPU/memory,
  active vs. max concurrent agent runs, admission decisions) and what is
  actually running right now (live pods by version, spawned subprocesses).
- **Resilience & Product** — are the failure modes documented in `CLAUDE.md`'s
  "Things that bit us" currently happening (provider circuit state, GitHub
  rate limit, main-branch-broken count), is maintenance still working
  (recurring-job staleness, provider-session table growth, auto-retry
  outcomes), is the escalation ladder trending down, and which
  features/plugins are used.

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

**Accurate: cache-mediated GLOBAL facts.** Queue depth, oldest age, orphaned
rows, plugin enablement, job/landing-queue state, worker CPU/memory, fleet
instance versions and spawned processes, provider circuit state, GitHub rate
limit, main-branch-broken count, maintenance staleness, and the escalation
ladder. Most of these carry a `syrus_global_` metric-name prefix; the newer
ones (e.g. `syrus_job_state`, `syrus_worker_cpu_percent`) don't, but every
panel whose `mode` is `:value` still declares `aggregate: :max` for the same
reason: the event that produced the number happened on one worker, but
`#sample!` writes it to a shared cache and `#refresh_gauges!` sets it from
that cache on whichever process serves `/metrics` — so every process renders
the same number, and the recorder's copy is the truth.

**Partial: genuinely per-process counters.** `syrus_feature_used_total` and
`syrus_admission_decisions_total` are incremented in whichever process
serves the request or makes the admission decision — currently web for
feature usage, whichever worker is deciding for `admission_decisions`. The
recorder runs on one worker, so it records only that process's share, which
is frequently zero.

That gap is the cross-process capture that is not built yet (see
`docs/plans/prometheus-dashboard.md`): worker pods fork one process per queue
definition sharing no memory, and are not scraped. The feature-usage and
admission-decisions panels are therefore present but thin until that lands, at
which point they fill in with no change to this plugin.

This is stated rather than hidden because a dashboard that quietly shows a
plausible-but-wrong zero is worse than one that shows nothing.

## Tabs

Each entry in `DashboardPayload::PANELS` declares a `category:` (one of
`DashboardPayload::CATEGORIES` — `queue_throughput`, `workers_fleet`,
`resilience_product`). The payload publishes that per panel plus a top-level
`categories` array in canonical display order, and the page renders one tab
per category with a panel grid underneath — the window selector and the
shared crosshair (`hoverIndex`) stay at the page level, above the tabs, since
both apply regardless of which tab is showing. The active tab is tracked in
the URL as a `tab` search param alongside the existing `window` one, so a link
to a specific tab is shareable and survives reload; an unrecognized or missing
`tab` value falls back to the first category.

A panel that forgets to set `category:` does not silently disappear from the
dashboard: `DashboardPayload.category_for` falls it back to `"other"`, and the
payload appends an `"other"` entry to `categories` only when some panel
actually needed it — so a real, correctly-categorized panel set never grows a
spurious "Other" tab. `dashboard_payload_spec.rb` additionally asserts every
declared panel has a real category, so drift here fails a spec rather than
waiting to be noticed as a mystery tab in production.

**Not every core metric has a panel.** `time_to_land_seconds`,
`run_duration_seconds`, and `workflow_step_duration_seconds` are histograms.
`TextFormatParser` drops every histogram family before a sample ever reaches
`metrics_dashboard_samples` — charting a quantile properly means re-deriving
it from buckets, which is outside what this plugin promises — so a panel
pointed at one of them would render permanently empty. They remain visible
through `/metrics` for an external Prometheus, which can derive real
quantiles from the buckets.

## Reading the panels

**Every panel shares one bucket grid.** The payload publishes `buckets` once, at
the top level, and each series carries one value per bucket — so index *i* is
the same instant in every chart. That is what makes a single crosshair across
all of them meaningful: hovering one chart shows what every other metric was
doing at that moment. Bucket size follows the window (1h -> 3m, 6h -> 5m,
24h -> 15m, 7d -> 1h), and the grid is aligned to the bucket size so two loads
of the same window agree on the timestamps.

**A bucket is never narrower than the recorder can sample.** The recorder
declares `tick_interval 1.minute`, but the plugin tick scheduler adds its own
poll latency: measured, samples land about every 89 seconds. The 1h window
originally bucketed at one minute, so roughly one bucket in three contained no
sample at all and every chart rendered as a comb of disconnected fragments —
the dashboard reporting an outage that was really just jitter.
`MetricsDashboard::SAMPLE_INTERVAL` records the real cadence and a spec holds
every window to at least twice it.

**Gauges are drawn as values; counters are drawn as rates.** A panel's `mode`
says which. `syrus_global_queue_ready_count` is a gauge — the chart shows the
highest reading in each bucket, since a spike that a later sample missed still
happened. `syrus_global_queue_failed_count` is a cumulative counter, and drawing
it raw gives a flat line at a large number: it sat at 3,319 all day, which says
nothing about whether anything is failing *now*. Rate panels show the change per
bucket instead, so 19 new failures read as 19. A decrease is treated as a
counter reset and the new value is counted, the same way PromQL's `rate()` does
— an in-memory counter returns to zero when its process restarts.

**Empty is not zero.** A rate panel reports a real `0` only inside the range it
actually observed; outside it, the bucket is `null` and the line breaks rather
than inventing an outage that did not happen.

**A gauge, though, holds its value.** A bucket with no sample means nobody
looked, not that the quantity vanished — so a gauge carries its last reading
forward rather than punching a hole. That carry is bounded by
`DashboardPayload::STALENESS` (5 minutes, the same bound and the same reasoning
Prometheus uses): past it the recorder has genuinely stopped, and a line still
drawing its last value there would be a confident lie of exactly the kind this
dashboard exists to avoid. So a short gap closes and a real outage still shows.

Rate panels keep only the series that moved, capped at
`DashboardPayload::RATE_SERIES_LIMIT`, so one busy job class is not buried under
a dozen flat ones.

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
