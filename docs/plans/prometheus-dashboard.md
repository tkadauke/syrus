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

A single authenticated `GET /metrics` on the **web** role, Prometheus text
format. Prefer the plain `prometheus-client` registry over Yabeda unless we
want Yabeda's Rails/Sidekiq presets — most of what we need is gauges computed
from SQL, not counters incremented in request paths.

Two categories, and they need different implementations:

**Gauges computed on scrape** (queue depth, backlog age, landing queue). These
are aggregate SQL. Scrape interval 15-30s; cache results for ~10s so a
scrape storm cannot hammer the queue DB. Every query here must be indexed and
bounded — a `/metrics` endpoint that is itself slow makes the outage worse.

**Counters accumulated in-process** (runs started/finished, admission
decisions). Multi-process: each web/worker pod exposes its own, Prometheus
scrapes each pod separately and sums. Do **not** try to centralize these.

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
