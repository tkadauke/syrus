# Metrics

Syrus exposes aggregate metrics in the Prometheus text exposition format at
`GET /metrics`. This is step 1 of the plan in
`docs/plans/prometheus-dashboard.md`; the worker exporter, the single-replica
global exporter, Grafana dashboards, telemetry and the embedded dashboard plugin
are later steps and are not built yet.

## Why it exists

Production "felt slow" on 2026-09-13 and it took about an hour of `kubectl` and
ad-hoc SQL to find the cause: the polling queue was 2,715 jobs deep with its
oldest job 190 minutes old, and growing. Polling is the product's clock — there
are no inbound GitHub callbacks — so everything GitHub-driven was arriving three
hours late while every health signal an operator would check looked fine: `/up`
answering in 10ms, 40–70% node CPU headroom, no pod restarts.

The queue metrics below are that incident made visible.

## Scraping

```
GET /metrics
Authorization: Bearer <admin API token>
```

Same admin token as `/api/v1/admin/*`, so there is no new credential to manage.
Non-admin tokens get 403; anonymous requests get 401.

Deployments that prefer to restrict the endpoint at the network layer — a
NetworkPolicy admitting only the Prometheus pod — can set
`SYRUS_METRICS_PUBLIC=1` to drop the token requirement. That is safe here
because every metric is an aggregate with bounded labels: there is nothing
identifying to leak (see *Cardinality* below).

The endpoint is cheap on purpose. It renders in-memory state and runs no
aggregate queries, because an endpoint that queried the queue tables would get
slow at exactly the moment those tables are the problem.

**Scope:** currently served by the **web** role only. Worker pods run several
forked processes that share no memory, so scraping them needs a separate
exporter with a shared store; that is a later step. Until then, counters
incremented on workers are not yet exported.

## What is exposed

`docs/metrics-catalog.md` is the generated list of every core metric, with its
type, labels and description. Regenerate it with `bin/metrics-catalog` after
declaring a metric; `spec/docs/metrics_catalog_spec.rb` fails the build if it
drifts.

### Queue metrics

| Metric | Meaning |
|---|---|
| `syrus_global_queue_ready_count{queue}` | jobs waiting to be claimed |
| `syrus_global_queue_oldest_age_seconds{queue}` | age of the oldest waiting job |
| `syrus_global_queue_claimed_count{queue}` | jobs currently being worked |
| `syrus_global_queue_blocked_count` | executions held by a concurrency limit |
| `syrus_global_queue_failed_count{job_class}` | failed executions, top 15 classes |
| `syrus_global_queue_orphaned_rows` | unfinished job rows with no execution row |
| `syrus_global_queue_sample_age_seconds` | how old the underlying sample is |

**`syrus_global_queue_oldest_age_seconds` is the one to alert on.** Depth alone
is ambiguous — 500 fast jobs is healthy, 50 stuck ones is not — and age is what
tells them apart.

`syrus_global_queue_orphaned_rows` counts job rows that are unfinished *and*
have no execution row of any kind. Nothing can reach them: no worker will claim
them, and `clear_solid_queue_finished_jobs` skips them because they never
finished. There were 553,671 in production when this was written, 84% of the
queue table.

### Product-usage metrics

| Metric | Meaning |
|---|---|
| `syrus_feature_used_total{feature}` | feature invocations, by feature |
| `syrus_global_plugin_enabled{plugin}` | 1 when an installed plugin is on, 0 when off |

These answer "what is actually used?", so effort goes where people are rather
than where we guess they are. Two things about reading them:

**A zero is a result.** Every feature in `Metrics::ProductUsage::FEATURES` is
published at 0 on boot, so a flat line at zero means "shipped, nobody uses it" —
which is the finding you are looking for — rather than "we forgot to measure".
An absent series means the feature was never instrumented.

**`syrus_global_plugin_enabled` disambiguates silence.** A disabled plugin
declares no metrics at all, so its absence is otherwise ambiguous: switched off,
or enabled and unused? This gauge separates the two. Without it, a product
decision made on that silence errs in the expensive direction — concluding
nobody wants a feature that was merely switched off.

Features are counted at the **web request that asks for them**, not inside the
worker that later performs the work. A retried Run is not a second use, and web
is currently the only role scraped. `Metrics::ProductUsage::FEATURES` is a
closed enum; `record` raises on an unknown key in development and test, and
ignores it in production. Adding a feature means adding it to that list, which
is the point — product analytics is exactly where a user-supplied string gets
passed as a label, and that is how a metrics system acquires unbounded
cardinality.

## Aggregating: `max by`, never `sum`

Metrics prefixed `syrus_global_` are **one fact about the whole cluster**, not a
per-pod value. They are sampled once a minute by `SampleGlobalMetricsJob` into the cache, and every pod that serves `/metrics` renders the same numbers.

```promql
max by (queue) (syrus_global_queue_oldest_age_seconds)   # correct
sum by (queue) (syrus_global_queue_oldest_age_seconds)   # wrong: N x the truth
```

Summing across pods multiplies the value by the number of pods scraped. The
`syrus_global_` prefix exists to make that rule legible from the metric name.

Non-global metrics are per-process and aggregate normally.

## Staleness

If `SampleGlobalMetricsJob` stops running, the gauges would otherwise keep
reporting whatever they last saw — confidently showing a healthy queue during
exactly the incident they exist to catch. Two things prevent that:

- `syrus_global_queue_sample_age_seconds` publishes how old the sample is, so
  freshness is assertable: alert when it exceeds a few minutes.
- The cached sample expires after 5 minutes, after which the gauges disappear
  rather than lying.

The sampler runs on `control_plane`, not `polling`: these gauges exist to reveal
a polling backlog, so sampling them from behind that backlog would hide the very
thing they measure.

## Counters never reset

Counters are cumulative and monotonic. They only go up, and rates are computed
at read time:

```promql
rate(syrus_some_total[5m])
```

There is deliberately no "per-interval counter" that resets on a schedule. That
model (StatsD's) loses data whenever a flush is missed and supports only one
consumer. With cumulative counters a missed scrape costs resolution rather than
data, any number of consumers can read independently, and PromQL compensates for
the one legitimate reset — a process restart, where the series drops to zero.

## Cardinality

Labels must come from `Syrus::Metrics::TagAllowlist::ALLOWED`, and declaring a
metric with anything else raises at boot. `job_id`, `run_id`, `sha`, `branch`,
repository slugs and user emails are all rejected by name, with an explanation.

One unbounded label turns one metric into millions of series, which is the
standard way to destroy a Prometheus install. It also carries a second job: the
metric store structurally cannot contain a repository name, an issue title, a
prompt or a diff, which is what will let telemetry share aggregates later
without a scrubbing pass to get wrong.

High-cardinality detail belongs in the event tables that already exist for it —
`mcp_tool_usages`, `performance_log_events` and friends. Metrics do not replace
them; those answer "what happened to *this* run", which a metric cannot.

## Declaring a metric

Core metrics are declared next to the subsystem they measure, so the metric and
its instrumentation cannot drift apart:

```ruby
Syrus::Metrics.declare do
  counter :runs_total, tags: %i[state trigger_kind], comment: "Runs by terminal state"
  histogram :run_duration_seconds, buckets: [ 1, 5, 60, 300, 1800 ], comment: "Run wall clock"
end

Syrus::Metrics.counter(:syrus_runs_total).increment(tags: { state: "succeeded", trigger_kind: "initial" })
```

Because declarations live in class bodies, the owning class has to be loaded for
its metrics to exist. `config/initializers/metrics.rb` lists core metric owners
for that reason — add to it when a new subsystem starts declaring.

Plugins declare in their manifest instead, and the registry applies a
`syrus_<plugin>_` prefix so a plugin cannot declare into core's namespace:

```ruby
syrus_plugin "git_history" do
  metrics do
    counter :relay_requests_total, tags: %i[outcome], comment: "Bare-clone reads served"
  end
end
```

Plugin metrics follow `while_enabled` semantics: a **disabled plugin declares
nothing and emits no series**. That is deliberate — absent means "not
applicable", whereas a zero would mean "enabled, and nobody uses it".

Three instrument types, and no Summary: client-side quantiles cannot be
aggregated across processes, since there is no function of two pods' p99 values
that yields the combined p99. Histograms aggregate because their buckets are
counters, at the cost of a quantile bounded by bucket width — so choose buckets
deliberately rather than accepting a default.

## Guarantees instrumentation relies on

Metrics code runs in hot paths and inside `ensure` blocks, so:

- **It never raises in production.** An undeclared metric raises in development
  and test, where it is a programming error, and degrades to a logged no-op in
  production. A metrics bug must not fail a Run.
- **It never blocks.** No IO, no database, no network on the instrumentation
  path.
