# Prometheus + Grafana dashboards for Syrus

Status: plan, not yet implemented.

## Why

On 2026-09-13 production "felt slow". It took roughly an hour of manual
`kubectl` and ad-hoc SQL to establish what was actually wrong, and the answer
was a single number that nothing exports:

```
polling queue:  2,715 jobs ready, oldest 190 minutes old, and growing
```

Syrus has no inbound GitHub callbacks — polling *is* the product's clock. A
three-hour polling backlog means new issues, PR feedback, CI results and merge
states all reach Syrus three hours late, while every health check an operator
would think to run looks fine: `/up` answers in 10ms, nodes have 40-70% CPU
headroom, no pod is restarting.

That is the shape of every problem worth a dashboard: **the thing that is broken
is invisible from the things that are monitored.** The goal here is that the
next version of this incident is one glance, not one hour.

Three more findings from the same session, all of which should have been panels:

- `solid_queue_jobs` holds 658k rows, of which **553,671 are orphaned
  `IndexTestCaseSearchJob` rows** created 2026-08-18/19 — `finished_at IS NULL`,
  present in neither `ready` nor `blocked`, so unreachable by work *and* by
  `clear_solid_queue_finished_jobs`. Dead weight every dispatcher scans.
- **`provider_sessions`: 5,001 rows occupying 6.0 GB** (~1.25 MB/row of
  `transcript_jsonl`), retained back to 2026-05-14 despite a
  `prune_provider_sessions` recurring task.
- Total data **20 GB against a 6 GB `innodb_buffer_pool_size`** — 3.3x
  oversubscribed.

## What already exists

| Piece | State |
|---|---|
| `PerformanceLogging` (`record_sql`, `record_request`, `record_job`, `phase`) | exists, writes `performance_log_events` |
| `Observability::EventStream` | exists, batched operational events |
| `InstanceVersion` heartbeats | exists, per-pod liveness + git SHA |
| `SpawnedProcess` inventory + host metrics | exists, per-subprocess CPU/RSS |
| Worker host health samples | exists, feeds `RunHostAdmission` |
| `/up` | exists, boot-only liveness |
| **A `/metrics` endpoint** | **does not exist** |
| **Any Prometheus/Grafana** | **does not exist** |

So the data mostly exists inside Syrus already; what is missing is a scrape
surface and somewhere to look at it. This plan deliberately does not add new
instrumentation where an existing table already holds the answer.

## Architecture

```
                    ┌─────────────────────┐
  kube-state-metrics│                     │
  node-exporter ───►│    Prometheus       │◄─── mysqld-exporter (sidecar on MySQL)
  syrus /metrics ──►│  (per environment)  │
                    └──────────┬──────────┘
                               │
                        ┌──────▼──────┐
                        │   Grafana   │  one dashboard set, env-templated
                        └─────────────┘
```

- **`kube-prometheus-stack`** (Helm) gives Prometheus, Grafana, Alertmanager,
  node-exporter and kube-state-metrics in one install. Infra panels come free.
- **`mysqld-exporter`** as a sidecar on the MySQL pod. See the MySQL section
  below for the collectors that matter — the defaults are not enough.
- **A Syrus `/metrics` endpoint** is the piece that does not exist and is where
  all the Syrus-specific truth lives. This is the only real code to write.

### Environments

Staging and production get **separate Prometheus instances** and the **same
dashboard JSON**, distinguished by an `env` external label
(`env="production"` / `env="staging"`). Same panels, same alert expressions,
one Grafana able to query both datasources. Identical dashboards are the point:
comparing staging against prod is how you tell "this is a regression" from
"this is Tuesday".

Dashboard JSON is checked into this repo and provisioned from a ConfigMap, not
hand-edited in the Grafana UI — otherwise the two environments drift within a
week and neither is trustworthy.

## The Syrus exporter

An authenticated `GET /metrics`, Prometheus text format. See the metrics
subsystem design at the end of this document for the library choice (Yabeda),
the instrument model, and the global-vs-per-pod question — this section is only
the metric inventory.

Two categories, implemented differently:

**Gauges over global state** (queue depth, backlog age, landing queue). These
are aggregate SQL and must *not* run on the scrape path — they are sampled on a
timer into Solid Cache and rendered from there, so `/metrics` never touches the
database. Every query behind them must be indexed and bounded.

**Counters accumulated in-process** (runs started/finished, admission
decisions). Each pod exposes its own and Prometheus sums across pods. Do **not**
try to centralize these.

### Metric inventory

Queue health — the row that would have caught this incident:

```
syrus_queue_ready_count{queue}              gauge
syrus_queue_oldest_age_seconds{queue}       gauge   ← the single most valuable metric
syrus_queue_claimed_count{queue}            gauge
syrus_queue_blocked_count{queue}            gauge
syrus_queue_failed_count{job_class}         gauge
syrus_queue_orphaned_rows                   gauge   ← would have found the 553k
syrus_queue_table_rows                      gauge
```

`syrus_queue_oldest_age_seconds` is the metric to build first. Depth alone is
ambiguous (500 fast jobs is fine, 50 stuck ones is not); age is not.

Product throughput:

```
syrus_runs_total{state,trigger_kind}        counter
syrus_run_duration_seconds{step_kind}       histogram
syrus_jobs_landed_total                     counter
syrus_job_state{state}                      gauge
syrus_landing_queue_depth{blocked_reason}   gauge   ← LandingQueueProcessor already computes these
syrus_time_to_land_seconds                  histogram
```

Workers and admission:

```
syrus_worker_cpu_percent{hostname}          gauge   ← from existing host health samples
syrus_worker_memory_percent{hostname}       gauge
syrus_active_agent_runs                     gauge
syrus_max_concurrent_agent_runs             gauge   ← so the panel shows the ceiling
syrus_admission_decisions_total{decision}   counter
syrus_workflow_step_duration_seconds{kind}  histogram
```

Fleet:

```
syrus_instance_versions{role,version}       gauge   ← two versions during a rollout
syrus_spawned_processes{kind,state}         gauge
```

## MySQL metrics

Syrus is unusually MySQL-dependent: four databases (primary/cache/queue/cable),
a queue that polls hot tables continuously, and 20 GB of data. The defaults of
`mysqld-exporter` will not surface the problems we actually hit.

### Enable these collectors explicitly

```yaml
--collect.info_schema.tables           # per-table data + index bytes  ← REQUIRED
--collect.info_schema.tablestats       # per-table read/write counts
--collect.info_schema.innodb_metrics   # buffer pool, row locks, redo
--collect.perf_schema.eventsstatements # top query digests by total latency
--collect.perf_schema.tableiowaits
--collect.perf_schema.indexiowaits
--collect.global_status
--collect.global_variables
```

`--collect.info_schema.tables` is the one that must not be skipped: it is how
`provider_sessions` at 6 GB becomes a panel instead of a discovery. Note it is
off by default in some chart versions, and it has a real cost on a schema with
many tables — scrape it on a longer interval (60s) than the rest.

### What to watch, and why — Syrus-specific

**Working set vs buffer pool.** The finding that matters most and the one no
stock dashboard shows, because it needs two metrics divided:

```promql
sum(mysql_info_schema_table_size{component="data_length"} +
    mysql_info_schema_table_size{component="index_length"})
  / on() mysql_global_variables_innodb_buffer_pool_size
```

Today this is **3.3**. Alert above 0.8. Above 1.0 the pool can no longer hold
the working set and every cold query becomes disk IO.

**Per-table growth.** `mysql_info_schema_table_size` by table, top 10, plus its
`deriv()` over 24h. Three of our tables grow without bound in practice
(`provider_sessions`, `test_insight_cases`, `job_logs`) and each has a pruning
task that is supposed to stop that. A growth panel is how you learn a pruner
has silently stopped working — which is exactly the `provider_sessions` case
(rows dating to 2026-05-14 with `prune_provider_sessions` scheduled).

**Buffer pool hit ratio.**

```promql
1 - rate(mysql_global_status_innodb_buffer_pool_reads[5m])
  / rate(mysql_global_status_innodb_buffer_pool_read_requests[5m])
```

Currently ~99.97% cumulative, which is healthy — worth stating plainly, because
it means today's slowness is *not* MySQL cache thrash and the ratio panel would
have correctly steered us away from that theory. Alert below 99%.

**Row lock waits and deadlocks.**

```
mysql_global_status_innodb_row_lock_waits
mysql_global_status_innodb_row_lock_time_avg
```

We have specific history here: fan-out jobs bulk-inserting into
`solid_queue_jobs` deadlocked under MySQL's default REPEATABLE READ, fixed by
pinning `transaction_isolation: READ-COMMITTED` on the `queue` and `cable`
connections (see CLAUDE.md). The `primary` and `cache` connections were
deliberately left on the default. A row-lock panel is the early warning if a
new bulk-insert path lands on one of those.

**Slow queries.** `rate(mysql_global_status_slow_queries[5m])` as the coarse
signal (cumulative count is 119,624 and by itself means little), with
`mysql_perf_schema_events_statements` for the top digests by total latency —
total, not average, since our pain is high-frequency queue polling rather than
one slow report.

**Temp tables spilling to disk.**
`rate(mysql_global_status_created_tmp_disk_tables[5m])`. Cheap to collect and a
good proxy for a query plan that regressed after a schema change.

**Connections.** `mysql_global_status_threads_connected` against
`mysql_global_variables_max_connections`, and `threads_running` as the
saturation signal (9 today — not saturated). With four databases and several
pods each holding a pool, connection exhaustion is a plausible future failure
and is invisible until it is total.

### What mysqld-exporter cannot tell us

These need the Syrus exporter, because they are semantic rather than statistical:

- **Orphaned queue rows.** "A job row with `finished_at IS NULL` and no
  execution row" is a Syrus/Solid Queue concept. MySQL sees a healthy table.
- **ActiveRecord pool saturation.** Checkout wait time lives in the Rails
  process, not the server. `ActiveRecord::Base.connection_pool.stat` per pod.
- **Slow SQL attributed to a controller or job.** We already record this in
  `performance_log_events` with `controller`/`action`/`job` context;
  mysqld-exporter only ever sees an anonymous digest.
- **Per-database breakdown by role.** The exporter reports schemas; mapping
  `syrus_production_queue` to "the queue" and alerting differently on it is ours.

### One caveat

`long_query_time`, `performance_schema` enablement, and
`innodb_buffer_pool_instances` were not re-verified for this document — the
worktree session could not run `kubectl exec` against the MySQL pod. Confirm
them before relying on the perf-schema collectors; if `performance_schema` is
off, the digest panels will be empty and need a MySQL restart to enable.

## Dashboards

Same JSON for both environments, `env` as a template variable.

**Row 1 — Is Syrus keeping up?** (opens the dashboard because it answers the
question that is actually asked)
- Queue oldest-age by queue (the headline single stat, red above 10 min)
- Queue depth by queue, stacked
- Backlog growth rate (`deriv`) — distinguishes "busy" from "losing"
- Failed executions by job class

**Row 2 — Product throughput**
- Jobs landed/hour; runs succeeded vs failed; failure ratio
- Landing queue depth by blocked reason
- Time-to-land histogram

**Row 3 — Workers**
- CPU/memory per worker pod (would have shown one worker at 3277m and another
  idle at 51m)
- Active agent runs vs the configured ceiling
- Admission decisions by outcome

**Row 4 — MySQL**
- Working set vs buffer pool ratio (single stat, the 3.3x panel)
- Top 10 tables by size + 24h growth
- Buffer pool hit ratio; slow query rate; row lock waits; threads running

**Row 5 — Infra**
- Node CPU/memory; pod restarts; ingress error rate and p99

## Alerts

Start with few enough that every page is real:

| Alert | Expression | For |
|---|---|---|
| Queue backlog stalled | `syrus_queue_oldest_age_seconds > 600` | 10m |
| Queue losing ground | `deriv(syrus_queue_ready_count[30m]) > 0` | 30m |
| DB exceeds buffer pool | working-set ratio `> 0.8` | 1h |
| Run failure ratio high | `> 0.2` | 1h |
| Queue starved | `rate(syrus_queue_completed_total[5m]) == 0 and syrus_queue_ready_count > 0` | 5m |
| MySQL hit ratio low | `< 0.99` | 15m |

The "queue starved" alert is the one that catches a whole class of silent
failure: work present, workers alive, nothing moving.

## Rollout

1. **`/metrics` with queue metrics only.** Queue depth, oldest age, orphan
   count. This alone would have turned today's hour into a glance. Ship it
   before anything else.
2. **`kube-prometheus-stack` in staging**, scrape Syrus + node + kube-state.
   Build Row 1. Verify the numbers against manual SQL before trusting them.
3. **mysqld-exporter + Row 4.** Get `--collect.info_schema.tables` on from the
   start.
4. **Product and worker metrics** (Rows 2-3) from existing tables.
5. **Promote to production**, same JSON, `env` label.
6. **Alerts**, once panels have been watched long enough to know normal.

## Open questions

- Retention and storage budget for Prometheus — 15d at 15s scrape is a rough
  starting point, but table-size series are cheap and worth keeping longer.
- Does Grafana live in this cluster or the homelab's existing one? A single
  Grafana with two datasources is the better operator experience.
- Authentication for `/metrics`: bearer token like the admin API, or network
  policy restricting it to the Prometheus pod. Prefer the latter.
- Should the exporter run on the web role only, or on workers too? Counters are
  per-process and need every pod scraped; gauges must be computed once. Likely
  answer: gauges on web, counters everywhere, `syrus_` prefix on both.

---

# Metrics subsystem design

## The premise worth correcting first

The hardest requirement stated for this system was: *"find a good way to reset
the time interval counters at the right time while exporting every counter
accurately."*

**Don't reset them.** That problem is an artifact of the push/delta model, and
the industry settled it by removing the reset rather than by timing it well.

| | Delta / push (StatsD) | Cumulative / pull (Prometheus) |
|---|---|---|
| Counter | accumulates, flushes, **resets** | **monotonic, never resets** |
| Rate computed | by the client, at flush time | by the query engine, at read time |
| Lost flush/scrape | **data lost** | resolution lost, data intact |
| Consumers | one (the flush target) | any number, independently |
| Reset timing | must be correct | does not exist |

In the cumulative model a counter only ever goes up. `rate(x[5m])` and
`increase(x[1h])` are computed at query time from two samples, and PromQL
explicitly handles the one legitimate reset — process restart, where the series
drops to zero — by detecting the drop and compensating. So "entries processed
per interval" is a monotonic counter plus `rate()`, and the interval is chosen
by whoever asks the question, not baked in at write time.

This is why the whole class of "did we reset before or after the scrape read
it?" bugs simply does not arise. **Adopt cumulative counters. The requirement to
reset them correctly is one to delete, not to satisfy.**

StatsD remains reachable as an *output* (see adapters) — the point is that our
internal model stays cumulative, because a delta is derivable from cumulative
state and never the reverse.

## Instrument types

- **Counter** — monotonic, only increments. Things that happen: runs started,
  queue entries processed, admission denials. Never `set`, never decrement.
- **Gauge** — goes up and down, sampled. Things that *are*: CPU percent, queue
  depth, active agent runs. The "absolute values" case.
- **Histogram** — bucketed observations for durations: run duration, step
  duration, time-to-land. Quantiles at query time without storing every sample.
  Buckets are declared per metric; a step duration spanning seconds-to-hours
  needs exponential buckets, not the defaults, which top out near 10s.

Deliberately omitted: **Summary**, because client-side quantiles cannot be
aggregated across pods. This is worth spelling out, since it is the reason
bucket choice matters so much later.

A Summary computes its quantiles inside the process. Say two pods report:

```
Pod A   1000 observations:  990 @ 10ms, 10 @ 200ms   → p99 = 200ms
Pod B     10 observations:   10 @ 800ms              → p99 = 800ms
```

The true fleet p99 over all 1010 observations is **200ms** (sorted ascending,
the 1000th value). But:

```
avg(200, 800) = 500ms     2.5x too high
max(200, 800) = 800ms     4x too high
```

There is no function of `(p99_A, p99_B)` that yields `p99_combined`. Quantiles
are not linear and carry no weight information — recovering the combined
quantile needs the full distributions and their counts, which a Summary has
already discarded. Pod B's tiny sample dominates any naive combination.

A Histogram aggregates because its buckets are **counters** ("N observations
≤ le"), and counters sum:

```promql
histogram_quantile(0.99, sum by (le) (rate(syrus_run_duration_seconds_bucket[5m])))
```

Summing bucket counts across pods reconstructs the true combined distribution;
the quantile is then estimated by interpolating inside whichever bucket crosses
the 99% mark.

The honest trade: a Summary's quantile is *exact but local*; a Histogram's is
*approximate but global*. The approximation is bounded by bucket width — with
boundaries at `[1, 5, 15, 60]` a true p99 of 7s is interpolated somewhere
between 5 and 15. In a multi-pod fleet, globally-correct-and-approximate beats
locally-exact-and-meaningless, which is why buckets must be placed where the
resolution is actually needed rather than left at defaults.

## Topology: what makes export nearly free

The two roles differ, and the difference decides the implementation. Verified
against production rather than assumed:

**Web** runs **single-process, multi-threaded** (no `workers` directive in
`config/puma.rb`). One process, one heap, in-memory registry, done.

**Workers do not.** `bin/jobs` is a Solid Queue *fork supervisor*: it forks one
process per worker definition in `config/queue.yml`, and they share no memory.

```
syrus-worker-compute-*   4 procs   supervisor, dispatcher, [resume,runs], [merges]
syrus-worker-home-*     11 procs   supervisor, dispatcher, scheduler,
                                   [resume,control_plane], [polling], [indexing],
                                   [cleanup], [low_priority_maintenance],
                                   [chat], [videos], [connectivity]
```

So the "no multiprocess machinery needed" simplification holds for web **only**.
On worker pods a counter incremented in the `runs` process is invisible to any
other process, including whichever one serves `/metrics`.

This also means a scrape target must exist on worker pods at all — and they are
the *primary* target, since nearly every interesting counter (runs, steps,
admission decisions, agent invocations) is incremented there while web pods
mostly serve the SPA.

Implementation per role:

- **Web**: expose `/metrics` from the Rails app. Trivial.
- **Worker**: run a small Rack server on a dedicated port (9394) inside the
  supervisor process, with `prometheus-client`'s **`DirectFileStore`** pointed at
  an `emptyDir` shared by the forked children. Each child writes counters to
  mmap'd files; the exporter reads and aggregates them. This is precisely what
  DirectFileStore exists for, and it is the standard Ruby answer to forked job
  runners. Prometheus discovers these via a `PodMonitor` on port 9394.

If Puma is ever switched to cluster mode, web joins the worker case and needs
the same treatment; that change should cite this section.

`/metrics` therefore serializes in-memory state and **never touches the
database**. That rule is what keeps it cheap, and it should be enforced by a
spec rather than by discipline: a metrics endpoint that queries the DB becomes a
liability exactly when the DB is the thing struggling.

## Opportunistic observation

Capturing queue length where it is already looked up is right, and is standard
practice — instrument where the value exists rather than re-deriving it:

```ruby
# in LandingQueueProcessor, which already computed this
Syrus::Metrics.landing_queue_depth.set(entries.size, tags: { reason: key })
```

But it has a failure mode that must be designed for: **an opportunistic gauge
goes stale silently.** If the code path stops being hit — because work stopped,
which is precisely the incident we want to detect — the last value keeps being
exported and the dashboard shows the system as it was, confidently and wrongly.
A queue-depth gauge frozen at 12 during an outage is worse than no gauge.

Two mitigations, both needed:

1. Pair each opportunistic gauge with
   `syrus_<name>_last_observed_timestamp_seconds` so alerts can assert freshness.
2. For gauges that must be trustworthy *during* an outage — queue depth and
   oldest-age above all — do not rely on opportunistic observation. Sample them
   on a timer.

Opportunistic observation is for cheapness on the hot path. Anything that
answers "is the system stuck?" gets an active sampler.

## Global vs per-pod metrics

The real subtlety, and the easiest thing to get wrong.

- **Per-pod** (CPU, this pod's counters, its active runs): labeled by instance,
  aggregated in PromQL. No coordination needed.
- **Global facts** (queue depth, landing queue depth, table sizes): one truth
  about the cluster. If six pods each export
  `syrus_queue_ready_count{queue="polling"}`, Prometheus gets six near-identical
  series and any `sum()` reports six times the real backlog.

Note this is a problem about **gauges**, not counters. Per-process counters sum
correctly across pods by construction; it is the "one fact about the cluster"
gauges that duplicate.

| | A. Render on every pod | B. Web pods only | C. Single-replica exporter | D. Leader-elected |
|---|---|---|---|---|
| Series per metric | 6 | 2 | **1** | 1 |
| `sum()` result | 6x wrong | 2x wrong | **correct** | correct |
| Relies on `max by` discipline | yes | yes | **no** | no |
| Survives a pod dying | yes | yes | metric gaps | metric moves |
| New deployment | no | no | **yes** | no |
| Series churn on failover | — | — | no | **yes** |

The failure modes worth weighing:

- **A and B are the same bug at different scale.** Halving the duplication does
  not make `sum()` correct; it makes it wrong by 2 instead of 6, which is
  arguably worse because it is less obviously wrong. They also flap: six pods
  sample at slightly different instants, so `max` jitters between samples.
- **C gaps when the exporter dies.** This reads as a downside and mostly is not:
  a gap is honest, whereas a stale duplicate is a confident lie — the exact
  failure this document is trying to design out. Cover it with an
  `up{job="syrus-global-exporter"} == 0` alert, which is a real signal rather
  than silence.
- **D churns the `instance` label on failover.** Prometheus sees the old series
  end and a new one begin, which breaks `rate()` continuity and looks identical
  to a restart. Leader election is clever, and cleverness in a monitoring path
  is a liability precisely when you need to trust it.

**Recommendation: C.** It is the only option where the aggregation is
unambiguous by construction rather than by convention, and the worker topology
above means we are building a standalone exporter surface anyway. Global metrics
still take a `syrus_global_` prefix so the single-source rule is legible from the
metric name.

Note C solves only the *global* half. Per-pod counters still require scraping
every pod, because no central process can see another pod's heap — the two
mechanisms are complementary, not alternatives.

## Library choice

| | `prometheus-client` | **Yabeda** | Hand-rolled |
|---|---|---|---|
| Instrument once, export many formats | no | **yes** (Prometheus, StatsD, Datadog) | no |
| Declaration DSL | minimal | clean | ours to build |
| Rails / ActiveRecord / Puma presets | no | yes | no |
| Extra abstraction | none | one layer | none |

**Recommendation: Yabeda**, specifically because of the requirement to stick
with standard formats and plug into other tools. It is a thin facade over a
pluggable adapter set: metrics are declared once, and whether they leave as a
Prometheus scrape, a StatsD flush, or both becomes a deployment choice rather
than a code change. `yabeda-prometheus` first; `yabeda-statsd` later without
touching a call site.

Honest caveat: if Prometheus is the only consumer forever, Yabeda is a layer we
did not need and `prometheus-client` alone is simpler. The requirement is
explicitly multi-tool, so the layer earns its place — but this is the decision to
revisit if StatsD never materialises.

Exporting *to* StatsD does reintroduce delta semantics, because that is StatsD's
model. That is a property of that wire protocol, not of our internal state, and
is exactly why our own model stays cumulative.

## API sketch

```ruby
# Declaration — boot-time, one place, so the metric set is greppable
Syrus::Metrics.declare do
  counter   :runs_total,           comment: "Runs by terminal state",
                                   tags: %i[state trigger_kind]
  gauge     :active_agent_runs,    comment: "Agent invocations in flight on this pod"
  gauge     :global_queue_ready,   comment: "Ready jobs (GLOBAL — aggregate with max by)",
                                   tags: %i[queue]
  histogram :run_duration_seconds, comment: "Run wall clock",
                                   buckets: [1, 5, 15, 60, 300, 900, 1800, 3600, 7200]
end

# Use — cheap, non-raising, safe from anywhere
Syrus::Metrics.runs_total.increment(tags: { state: "succeeded", trigger_kind: "initial" })
Syrus::Metrics.active_agent_runs.set(3)
Syrus::Metrics.run_duration_seconds.measure(elapsed, tags: { step_kind: "implement" })
```

Two guarantees the wrapper must make, because this code runs in hot paths and
inside `ensure` blocks:

- **Never raises.** A metrics failure must not fail a Run. Rescue and log.
- **Never blocks.** No IO, no DB, no network on the instrumentation path.

## Cardinality

The standard way to destroy a Prometheus install, so state it as a rule:
**labels must have small, bounded value sets.**

Allowed: `queue`, `state`, `trigger_kind`, `step_kind`, `decision`, `role`.
Forbidden: `job_id`, `run_id`, `workflow_id`, `sha`, `branch`, `user_email`, and
repository slug on any instance with many repositories.

A guard spec should assert every declared metric's tags come from an allowlist.
High-cardinality identifiers belong in logs and `performance_log_events`, which
is what those already exist for.

## Open questions

- Scrape interval: 15s is the instinct; the global sampler's period must be at
  most that, or the gauge is older than the scrape reading it.
- `/metrics` on the web role only, or on workers too? Counters are per-process
  and need every pod scraped; global gauges would be duplicated. Leaning: expose
  everywhere, render globals only when `SYRUS_ROLE=web`, so the duplicate set is
  two and not six.
- Whether to backfill `performance_log_events` into histograms, or leave
  historical latency analysis where it already works.

---

# Product metrics, telemetry, and the embedded dashboard

Three later requirements — product-usage metrics, optional telemetry sharing for
self-hosted installs, and a dashboard embedded in Syrus itself — change the
architecture more than they first appear to, because two of them need Syrus to
**read** its own metrics rather than only export them.

## The architectural consequence

The design above is export-only, which is Prometheus's model: the app holds
current state cheaply, the TSDB owns storage, query and history. An embedded
dashboard and a telemetry payload both need *history*, and history means
storage. Taken naively that means reimplementing a time-series database inside
Rails, which is a bad idea and a large one.

The way out is that the embedded recorder should be **a client of the same
scrape endpoint Prometheus uses**, not a second instrumentation path:

```
   instrumentation (one API, always on)
              |
     in-process registry
              |
         GET /metrics  ---------------->  Prometheus (optional, external)
              |
              +-------------->  local recorder (optional, plugin)
                                      |
                                 rollup tables
                                      |
                          embedded dashboard  +  telemetry payload
```

Properties that fall out of this, and they are the reason to prefer it:

- **One instrumentation API.** Nothing in application code knows whether
  Prometheus, the embedded recorder, both, or neither is consuming.
- **The embedded dashboard and Grafana show the same numbers**, because they
  read the same endpoint. Divergence between "the built-in view" and "the real
  monitoring" is a classic and miserable bug class, designed out here.
- **Graceful scaling.** Single-host Docker installs get a dashboard with no
  extra infrastructure; large installs point real Prometheus at the same
  endpoint and disable the plugin. No migration, no re-instrumentation.

The recorder is deliberately *not* a TSDB. It stores fixed-resolution rollups
(1-minute samples for 30 days, then daily) which is enough for the dashboard
rows described earlier, and refuses to grow features toward arbitrary PromQL.
When someone needs that, they need Prometheus, and the endpoint is already
there.

Scope honestly: the recorder scrapes every pod, which is trivial for a
single-host Docker install (one process tree) and fine for a handful of pods. It
is not a fleet monitoring system and should say so in its own docs.

## Metrics as a consolidation, not a new thing

Syrus already implements this pattern nine times, each with its own schema,
pruner, reader and admin payload:

```
filter_usages                 mcp_tool_usages              run_resource_summaries
github_api_usage_rollups      operational_log_events       test_insight_runtime_summaries
main_branch_health_checks     performance_log_events       worker_host_health_samples
```

So "migrate the worker metrics in the admin UI onto the new system" is not
adding a system — it is **replacing nine partial ones**. That is the strongest
argument for building this properly, and equally an argument for doing it
incrementally rather than as one migration.

### But display and control must not be conflated

`worker_host_health_samples` is not only displayed. It is read by
`RunHostAdmission` and `WorkflowAdmissionBudget` — it is **control flow**. That
distinction decides how far the migration should go:

| | Display path | Control path |
|---|---|---|
| Consumer | dashboards, humans, alerts | admission decisions |
| Tolerates staleness | yes | **no** |
| Tolerates gaps | yes (a gap is visible) | **no** (a gap becomes a wrong decision) |
| Tolerates approximation | yes (bucketed quantiles) | **no** |
| May be dropped on error | **yes, by design** | no |

The metrics layer is explicitly best-effort: it never raises, never blocks,
drops rather than fails, and approximates by bucketing. Those are the right
properties for observability and exactly the wrong ones for a scheduler input.
An admission gate reading a gauge that is thirty seconds stale — or absent
because the exporter hiccuped — is a reliability regression bought for tidiness.

**So: migrate the display, keep the control path.** `WorkerHostHealthSampler`
keeps writing `worker_host_health_samples` as the authoritative, transactional
record that admission reads; it *additionally* emits the same values as gauges
for dashboards and telemetry. One sampler, two consumers, one of which is
allowed to miss a beat.

This is the instinct that "reacting to metrics adds too much complexity" — the
instinct is right, but the reason is sharper than complexity: it inverts a
dependency, putting a lossy subsystem underneath a correctness-critical one.

## Product metrics

Feature-usage counters, to answer "what is actually used?" and prioritize
accordingly. Ordinary counters at feature entry points:

```
syrus_feature_used_total{feature}            counter   # bounded enum of feature keys
syrus_mcp_tool_calls_total{tool}             counter   # mcp_tool_usages already collects this
syrus_workflow_started_total{trigger_kind}   counter
syrus_step_executed_total{step_kind}         counter
syrus_plugin_enabled{plugin}                 gauge     # 0/1 per installed plugin
syrus_chat_turns_total{mode}                 counter
```

Two cautions specific to this category:

- **`feature` must be a bounded enum declared in one place**, not a free string
  passed by callers. A free-form feature label is how a metrics system acquires
  unbounded cardinality, and product analytics is exactly where the temptation
  to pass a user-supplied string arrives.
- **Absence is the signal.** The point is to find features with *zero* usage, so
  the dashboard must distinguish "counter exists and is 0" from "no series
  exists". Declare product counters eagerly at boot with a zero value, so an
  unused feature reports 0 rather than vanishing.

## Optional telemetry

Syrus is installed and run by its users, so telemetry is a privacy decision
before it is an engineering one. The central collector is out of scope; the
client side is not, and its constraints are:

**Opt-in, never opt-out.** Default off, an explicit affirmative action to
enable, as easy to turn off again. A fresh install shares nothing.

**Allowlist at declaration.** A metric is shareable only if its declaration says
so. Default private. This puts the privacy decision in the diff, where review
can see it:

```ruby
counter :feature_used_total, tags: %i[feature], share: :aggregate
gauge   :global_queue_ready, tags: %i[queue]                       # not shared
counter :runs_total,         tags: %i[state trigger_kind], share: :aggregate
```

**Structurally incapable of carrying identifiers.** The cardinality allowlist
already forbids `job_id`, `sha`, `branch`, `user_email` and repository slugs as
labels. Telemetry inherits that, which means the shared payload cannot contain a
repository name, an issue title, a prompt or a diff — not by policy but because
no such value exists in the metric store to begin with. That is a far stronger
guarantee than a scrubbing pass, and it is the reason the cardinality rule is
non-negotiable rather than merely good practice.

**Transparency is a feature, not a disclosure.** The settings screen shows the
**exact payload**, rendered by the real serializer, before anything is sent —
not a prose description of what is "generally" collected. Plus a local log of
what was sent and when, so the claim stays auditable afterwards. If showing a
user the payload would embarrass us, the payload is wrong.

**Versioned and stable.** A `schema_version` on the payload, and adding a metric
to the shared set is a deliberate change with a changelog entry — otherwise
"opt in once" silently becomes consent to whatever gets added later.

Sketch:

```json
{
  "schema_version": 1,
  "install_id": "<random uuid, generated locally, resettable>",
  "syrus_version": "1.2.3",
  "period": { "from": "...", "to": "..." },
  "metrics": {
    "feature_used_total": { "chat": 412, "epics": 38, "video_walkthroughs": 0 },
    "runs_total": { "succeeded": 1328, "failed": 411 },
    "plugins_enabled": ["github_source", "claude_agent"]
  }
}
```

`install_id` is random, locally generated and resettable, and exists only to
deduplicate repeat submissions. It must not be derived from a hostname, licence
key, email or repository.

## The embedded dashboard plugin

A `metrics_dashboard` plugin, off by default, following existing plugin
conventions: a sidebar page with its `paths` fully declared (including any
detail route — otherwise direct navigation silently renders the bootstrap
shell), its own docs under `plugins/metrics_dashboard/docs/syrus_docs/`, and
`plugin_disabled` responses when off. Disabling it must also stop the recorder;
a disabled plugin should not keep writing rollup rows.

It renders the same rows as the Grafana dashboards, from the recorder's tables.
The deliberate constraint: **it is not a query builder.** Fixed panels answering
the questions this document opened with — is the queue keeping up, what is
landing, which features are used. Anyone needing ad-hoc queries has outgrown it,
and `/metrics` is already waiting for them.

## Revised rollout

The dependency order changes: recorder and dashboard are downstream of the
endpoint, and telemetry is downstream of the recorder.

1. Instrumentation API + in-process registry + `/metrics` (web, then workers via
   DirectFileStore).
2. Queue metrics, so the incident that started this document is visible.
3. Single-replica global exporter.
4. External Prometheus + Grafana (staging, then production).
5. Product-usage counters — cheap once the API exists, immediately useful.
6. `metrics_dashboard` plugin: recorder + rollups + panels.
7. Telemetry: payload, preview UI, opt-in, send. Last, because it depends on
   everything above and because the privacy surface deserves its own review.

Steps 1-4 stand alone and are worth doing regardless of whether 5-7 happen.
