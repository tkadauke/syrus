# Metrics

Syrus exposes aggregate metrics in the Prometheus text exposition format at
`GET /metrics`. This covers the queue-health, product-usage, landing-queue/
run-throughput, worker/admission, fleet, resilience, maintenance/pruner, and
escalation/attention metric groups from the plan in
`docs/plans/complete/prometheus-dashboard.md`; a genuine worker exporter (one that
scrapes every pod, not just web), the single-replica global exporter, Grafana
dashboards, telemetry and the embedded dashboard plugin are later steps and
are not built yet.

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
incremented on workers are not yet exported -- this currently applies to
`syrus_admission_decisions_total`, which is incremented wherever an admission
decision is made (see *Workers and admission* below), including on workers.
`syrus_worker_cpu_percent`/`syrus_worker_memory_percent`/`syrus_worker_disk_percent`
are not affected by this gap: they are sampled from the
`worker_host_health_samples` table (rows every worker writes on its own
heartbeat) into the same web-served cache the other GLOBAL gauges use, so
they are visible today even though no worker pod is scraped directly.

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
them, and the finished-job pruner skips them because they never finished. There
were 553,671 in production when this was written, 84% of the queue table.

`SolidQueueCleanupJob` now sweeps them, in its own larger batches because the
ordinary per-run budget would have taken two days to work through that backlog.
Only rows older than `ORPHAN_MIN_AGE` are eligible: Solid Queue creates a job
row and its execution row together, so a row without one is either an orphan or
an enqueue caught mid-flight, and the age guard is what tells those apart.

The same job sweeps **ready executions stranded on a dead `resume-` queue**. A
`resume-<storage-key>` queue is served only by the worker holding that storage;
once that worker is gone nothing advertises the queue, and a row on it can never
be claimed. `WorkEngine::Reconciler` already handles this for a *queued* Run
(`queued_run_on_dead_resume_queue`, which re-enqueues it onto a live queue) and
keeps that job — but it scans Runs, so a **terminal** Run's leftover row is
invisible to it and simply sits. That row is inert (RunJob returns early on a
terminal Run) but not harmless: while it sits it pins
`syrus_global_queue_oldest_age_seconds`, the headline number above, at an age
that only grows. A single such row had the dashboard reporting a 31-hour
backlog that did not exist.

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

### Landing queue and run throughput

| Metric | Meaning |
|---|---|
| `syrus_job_state{state}` | Jobs grouped by state |
| `syrus_landing_queue_depth{blocked_reason}` | approved/landing Jobs by why they are not landing yet, `"none"` meaning eligible |
| `syrus_queue_table_rows` | total Solid Queue row count across every table |
| `syrus_jobs_landed_total` | Jobs whose PR reached the base branch |
| `syrus_time_to_land_seconds` | wall clock from Job creation to landing |
| `syrus_runs_total{state,trigger_kind}` | Runs by terminal state |
| `syrus_run_duration_seconds{step_kind}` | Run wall clock by step kind |
| `syrus_queue_completed_total` | Solid Queue executions that finished |

`Metrics::LandingSampler` (`app/services/metrics/landing_sampler.rb`) owns all
eight. It runs on the same `SampleGlobalMetricsJob` recurring tick as
`Metrics::QueueSampler`, but the eight metrics split into two different
instrumentation shapes:

**`job_state`, `landing_queue_depth`, and `queue_table_rows` are gauges**,
sampled by aggregate query and cached exactly like the queue-health gauges
above — `refresh_gauges!` sets them from the cache on the scrape path, no
query. `landing_queue_depth` deliberately does **not** recompute
`LandingQueueProcessor#blockage_for` — that would be its own expensive
aggregate query on every tick. It reads the `landing_queue_blocked_reason`
column `LandingQueueProcessor` already persists onto each approved/landing Job
every 30 seconds, and keeps only the bounded `key` (e.g.
`"waiting_github_mergeability"`), never the `params` hash, which can carry a
Job slug.

**`jobs_landed_total`, `runs_total`, `run_duration_seconds`,
`time_to_land_seconds`, and `queue_completed_total` are counters and a
histogram**, which cannot be `set` the way a gauge can — `Counter`/`Histogram`
only ever accumulate (`#increment`/`#observe`), by design (see "Counters never
reset" above). So `#sample!` keeps a per-source cursor and, each tick, folds
every newly-finished Run/Job/queue-execution into a **cumulative snapshot**
cached under its own key — a running total per counter tag combination, and a
running bucket/sum/count per histogram tag combination — rather than mutating
the live instrument directly. `#refresh_gauges!` reads that snapshot back and
calls `Counter#reconcile!`/`Histogram#reconcile!` to overwrite this process's
local instrument to match it: the same `set`-like idempotency the three gauges
get from `Gauge#set`, just expressed as "catch up to the known total" because
that is the only vocabulary a monotonic instrument has. This matters because
`#sample!` runs from `SampleGlobalMetricsJob` on a **worker** process
(`control_plane` queue), while `/metrics` is served by a **web** process with a
completely separate in-process registry — mutating the counter/histogram
directly inside `#sample!` would be invisible to every real scrape, exactly
like an event counter incremented inside `RunJob` would be (see "Scraping"
above). Because `#refresh_gauges!` reconciles from the cache rather than
replaying `#sample!`'s own deltas, a web process that never ran a single tick
itself still renders the full accumulated total the first time it scrapes.
The cursor and the cumulative snapshot both bootstrap to "now" on their first
ever tick rather than backfilling the entire Job/Run history, the same
instinct as `Metrics::ProductUsage`'s zero-preset: counting starts from when
the sampler first runs, not from the beginning of time.

### Workers and admission

| Metric | Meaning |
|---|---|
| `syrus_worker_cpu_percent{hostname,storage_key}` | latest CPU utilization sample per worker storage identity, labelled with the current hostname for display |
| `syrus_worker_memory_percent{hostname,storage_key}` | latest memory utilization sample per worker storage identity, labelled with the current hostname for display |
| `syrus_worker_disk_percent{hostname,storage_key}` | latest data-root disk utilization sample per worker storage identity, labelled with the current hostname for display |
| `syrus_active_agent_runs` | currently running agentic Runs, subject to the global concurrency cap |
| `syrus_max_concurrent_agent_runs` | the configured ceiling, so the dashboard panel shows capacity alongside utilization |
| `syrus_admission_decisions_total{decision}` | admission decisions, tagged by the action taken |
| `syrus_workflow_step_duration_seconds{kind}` | Step wall clock from start to finish |

`Metrics::WorkerSampler` (`app/services/metrics/worker_sampler.rb`) owns the
first five. `worker_cpu_percent`/`worker_memory_percent`/`worker_disk_percent`
read the most recent `WorkerHostHealthSample` per durable
`worker_storage_key` within a 2-minute window, falling back to `hostname` only
for legacy rows written before that column existed. This is the same identity
split used by workflow resume routing in `multi_worker.md`:
`storage_key` anchors the dashboard series across Kubernetes pod restarts,
while `hostname` stays in the scrape labels as diagnostics/display data. The
Metrics Dashboard plugin groups these panels by `storage_key` but resolves each
visible series name from the latest scraped `hostname`, so operators see
recognizable pod names without making the changing pod name the continuity key.
The gauges are the panel that would have shown "one worker at 3277m and another
idle at 51m" instead of someone finding it by hand. `active_agent_runs` and
`max_concurrent_agent_runs` are plain gauges read from
`Run.running_agent_runs.count` and `AppSetting.max_concurrent_agent_runs`. All
five are GLOBAL and cache-mediated exactly like the queue-health and
landing-queue gauges above.

`workflow_step_duration_seconds` is a histogram and therefore goes through
the same cursor + cumulative-snapshot dance `run_duration_seconds` uses (see
above) -- `WorkerSampler` keeps its own cursor over `Step`'s
`started_at`/`finished_at`. It is deliberately a *different* metric from
`syrus_run_duration_seconds{step_kind}`: a Run's duration is one attempt, but
a Step's `started_at`/`finished_at` spans every repair/retry attempt inside
it, so a Step that failed once and was repaired still reports one wall-clock
duration for the whole Step rather than one per Run.

`syrus_admission_decisions_total` is the one metric in this group that is
**not** GLOBAL. Admission decisions happen inline in
`WorkflowAdmissionBudget#call` and `RunHostAdmission#call` -- see
`config/syrus_docs/multi_worker.md` -- and the counter is incremented at the
exact moment a decision is produced, in whichever process (web or worker)
made it. It is declared once, in `WorkflowAdmissionBudget`, and
`RunHostAdmission` increments the same declared counter for its own
`admit`/`defer` decisions rather than redeclaring it. Per *Aggregating*
below, this is fine for a per-process counter -- Prometheus sums it across
every pod that exposes it -- but see the *Scope* note above: until a worker
exporter exists, only decisions made on the web role's own process are
actually visible on a scrape.

### Fleet

| Metric | Meaning |
|---|---|
| `syrus_instance_versions{role,version}` | live pods by role and git SHA |
| `syrus_spawned_processes{kind,state}` | subprocesses running or recently finished, by kind and state |

`Metrics::FleetSampler` (`app/services/metrics/fleet_sampler.rb`) owns both,
sampled the same GLOBAL, cache-mediated way as the queue-health gauges --
plain snapshots, no cursor needed, since neither is a monotonic count.

`instance_versions` reads `InstanceVersion.fresh` (a live heartbeat within
the last two minutes) grouped by `role` and `version` -- "two versions during
a rollout" is the expected, informative reading this metric exists to show,
not a bug. `spawned_processes` reads `SpawnedProcess.recent_or_active`
(running, or finished within the last hour) grouped by `kind` and a `state`
of `"running"` or the process's terminal `outcome` (see
`SpawnedProcess::OUTCOMES`).

**`hostname` and `version` are allowed tags, as a deliberate, narrow
exception.** `Syrus::Metrics::TagAllowlist` otherwise forbids both -- pod
names and git SHAs churn across deploys, which is exactly the kind of
unbounded-over-time growth the allowlist exists to block. They are allowed
here because these gauges are sampled centrally from one process and cached,
not scraped per-pod: there is no Prometheus-assigned `instance` label to
lean on instead, since only the web role serves `/metrics` today. The set of
values alive at any moment stays small (the live worker fleet, "two versions
during a rollout"), which is what keeps this from becoming the per-request
unbounded case the rest of the allowlist guards against -- see the comment on
`Syrus::Metrics::TagAllowlist::ALLOWED` for the full reasoning.

### Resilience

| Metric | Meaning |
|---|---|
| `syrus_provider_circuit_state{provider}` | circuit state per configured agent provider |
| `syrus_github_rate_limit_remaining{credential_mode}` | lowest observed GitHub API rate-limit remaining, by credential mode |
| `syrus_github_app_rate_limit_remaining_percent` | lowest observed GitHub App installation rate-limit remaining percentage |
| `syrus_github_app_api_blocked_count` | active GitHub App installations currently marked API-blocked |
| `syrus_repositories_main_branch_broken_count` | repositories whose default branch health is currently broken |

`Metrics::ResilienceSampler` (`app/services/metrics/resilience_sampler.rb`) owns
all three, sampled the same GLOBAL, cache-mediated way as the queue-health and
fleet gauges above -- plain snapshots, no cursor needed, since none of the
three is a monotonic count. Each corresponds to a failure mode documented
elsewhere in this codebase as having already happened in production and
staying invisible outside a Rails console until someone went looking by hand
-- the same "everything looks fine except the one number that matters" shape
as the queue-backlog incident that motivated this whole metrics plan.

**`provider_circuit_state`** reads `ProviderCircuitBreaker.call` for every
provider `User.agent_providers` knows about, not just the ones a user has
configured -- the same "publish a known key even when it has nothing to
report" instinct as `Metrics::ProductUsage.preset_all!`, so a closed provider
reads as an explicit `0` rather than an absent series. `ProviderCircuitBreaker`
already suppresses automatic retries and CI repair during provider-wide
transient outages (see `CLAUDE.md` "Failure resilience"). This gauge does not
implement the classic three-state circuit breaker (closed/half-open/open):
`ProviderCircuitBreaker` itself only distinguishes closed and open, and splits
open into an ordinary transient-failure open and a longer-lived usage-limit
exhaustion open (see `ProviderCircuitBreaker::USAGE_LIMIT_OPEN_FOR`). The
gauge's three values follow that real distinction instead of inventing a
half-open state that does not exist in the code: `0` closed, `1` open
(transient failures), `2` open (usage limit exhausted).

**`github_rate_limit_remaining`** reads the `gh_rate_limit_remaining` column
GitHub's response headers already persist onto whichever record authenticated
the request (`GithubClient#persist_rate_limit_headers!`) -- an `Installation`
for GitHub App auth (`credential_mode="app"`), a `User` for personal-access-token
auth (`credential_mode="pat"`), matching `Job#credential_mode`'s own values.
The gauge reports the *lowest* remaining count observed across every
Installation/User in each mode, because a single exhausted installation or
user token can stall polling for everything it authenticates just as
effectively as an instance-wide exhaustion would -- worst case is the
informative reading here, the same instinct `Metrics::WorkerSampler` uses for
"one worker at 3277m and another idle at 51m." A credential mode with no
observation yet (nobody has made a tracked GitHub call under it) is omitted
rather than reported as `0`, which would misread as "exhausted."

**`github_app_rate_limit_remaining_percent`** is the same GitHub response
header data restricted to active GitHub App installations and normalized by
each installation's current limit before taking the lowest value. The
dashboard uses this as the App-specific saturation view because installation
limits vary; 700 remaining requests can be healthy for one installation and
nearly exhausted for another. It is intentionally unlabelled rather than
tagged by installation or account, because those identifiers grow with the
number of connected installations and belong in admin tables, not Prometheus
series. **`github_app_api_blocked_count`** counts active installations with
`gh_api_blocked_at` set, which is the state that drives the in-app GitHub App
rate-limit banner.

**`repositories_main_branch_broken_count`** counts repositories where
`Repository#main_health_broken?` is true. `StepDispatcher` pauses every
workflow on the instance, including landing, while any repository's main
branch health is broken (`StepDispatcher::MAIN_HEALTH_BLOCK_REASON`, see
`CLAUDE.md` "Main-branch health & repair") -- this gauge is what makes that
instance-wide stall condition visible on the dashboard instead of requiring
someone to notice landing has gone quiet. It reports only a count, never
repository names or ids, per the cardinality rule below.

### Maintenance and pruners

| Metric | Meaning |
|---|---|
| `syrus_recurring_job_last_success_seconds{job}` | seconds since a `config/recurring.yml` job last completed successfully |
| `syrus_provider_sessions_bytes` | total `transcript_jsonl` bytes across all `provider_sessions` rows |
| `syrus_provider_sessions_rows` | total `provider_sessions` row count |
| `syrus_auto_retry_attempts_total{skip_reason}` | auto-retry attempts by settled outcome |

`Metrics::MaintenanceSampler` (`app/services/metrics/maintenance_sampler.rb`)
owns all four. Motivating incident: `provider_sessions` reached 6.0 GB, rows
dating back over a month, because the `prune_provider_sessions` recurring
task had silently stopped -- invisible outside a Rails console until someone
went looking by hand, the same shape as every other incident this metrics
effort exists to catch.

**`recurring_job_last_success_seconds`** is a generic staleness signal
covering every job declared in `config/recurring.yml` -- pruners chief among
them, but every recurring job gets covered without a bespoke gauge per table.
`job` is the `config/recurring.yml` key (`prune_provider_sessions`,
`reap_stale_runs`, ...), not the underlying Solid Queue class name.
`Metrics::QueueSource#recurring_job_last_success_at` reads the most recent
`solid_queue_jobs.finished_at` per configured job's class. That table alone is
not sufficient: Solid Queue prunes finished job rows after
`SolidQueue.clear_finished_jobs_after` (1 day by default), far shorter than
the staleness this gauge exists to catch. `Metrics::MaintenanceSampler` keeps
its own durable high-water mark in the cache (100-day TTL), advanced forward
on every tick that observes a newer success and otherwise left alone -- so a
job that has not actually succeeded in weeks keeps growing this gauge instead
of the evidence aging out of `solid_queue_jobs` and making it look merely
unobserved. A job with no recorded success at all (never run, or nothing
observed since the sampler started) is omitted rather than reported as `0`,
which would misread as "just succeeded."

**`provider_sessions_bytes`/`provider_sessions_rows`** are `provider_sessions`
table headline gauges, sampled directly (`SUM(LENGTH(transcript_jsonl))` and
`COUNT(*)`) given the table's history and its `prune_provider_sessions`
pruning task.

**`auto_retry_attempts_total`** counts every settled `AutoRetryAttempt` --
performed (`skip_reason="none"`) or skipped -- the same cursor-over-`updated_at`,
cache-mediated counter shape `Metrics::LandingSampler` uses for `runs_total`.
`CLAUDE.md`'s "Failure resilience" section documents production hitting an
unbounded auto-retry accumulation bug twice: a permanent skip condition
(`"failure classification changed"`, written for a verdict that had not
changed) sat in `AutoRetryAttempt::BUDGET_EXEMPT_SKIPPED_REASON_PREFIXES`, so
every resulting skip did not count against the retry budget, and the
reconciler kept proposing another attempt -- production reached roughly
460,000 attempts at two per second before anyone noticed. `skip_reason` is a
bounded category (`AutoRetryAttempt.skip_reason_category`), not the raw
`skipped_reason` string -- that string routinely interpolates a
classification name or a schedule time, which would make it an unbounded
label. Categories mirror `BUDGET_EXEMPT_SKIPPED_REASON_PREFIXES` one-to-one,
plus `not_retryable` for `AutoRetryAttempt::NOT_RETRYABLE_SKIP_PREFIX` (a
skip that correctly counts against budget) and `other` for anything
unrecognized -- so a rate spike on one budget-exempt category is a direct
instrument for that exact regression recurring, without waiting for the
Job/Workflow-level symptoms to show up first.

### Escalations and attention

| Metric | Meaning |
|---|---|
| `syrus_escalations_per_landing_ratio` | escalations opened per landing over the trailing window |
| `syrus_attention_items_open_total{problem_code}` | currently open, unexpired AttentionItems by problem code |

`Metrics::AttentionSampler` (`app/services/metrics/attention_sampler.rb`) owns
both, wiring up `Metrics::EscalationsPerLanding` and `AttentionItem` --
services that were fully implemented but exported nowhere: not on `/metrics`,
not on the `metrics_dashboard` plugin, not on any admin page. Both are GLOBAL
gauges, sampled the same cache-mediated way as the queue-health gauges above
-- plain snapshots, no cursor needed, since neither is a monotonic count.

**`escalations_per_landing_ratio`** is the Workflow Engine V3 "one metric"
(see `docs/plans/workflow-engine-v3.md` and `Metrics::EscalationsPerLanding`):
escalations (distinct `AttentionItem`s opened in the trailing window, one per
problem rather than per occurrence) divided by landings (`auto_merge`/
`merge_train` Workflows that succeeded in the same window). Trending down
means the attention ladder is learning to resolve problems below the level
that needs a human; flat means it isn't. `Metrics::EscalationsPerLanding::Result#ratio`
is `nil` when nothing landed in the window -- an infinity would read as a
number, and "no landings" is the honest answer -- so `#refresh_gauges!`
`Gauge#clear`s the gauge in that case rather than `set`ting a misleading `0`.
It does the same on a cache miss (the sampler has stopped, or has not run
yet): a stale ratio from an earlier tick left `set` on the live instrument
past its `CACHE_TTL` would render as "still healthy" through the exact outage
this gauge exists to surface, so absence takes priority over staleness the
same way the maintenance-and-pruners gauges above prefer an omitted job over
a fabricated zero.

**`attention_items_open_total`** reads `AttentionItem.open_decisions.unexpired`
(the same scope `AttentionItem.queue_summary` uses) grouped by `problem_code`
across both the `operator` and `triage` queues -- the current size of the
human-attention backlog, broken down by what kind of problem is waiting.
`problem_code` is on the cardinality allowlist because `Problem::Kind` is a
closed, bounded registry (see `config/syrus_docs/attention_items.md` and
`app/models/problem/kind.rb`), not a free-form string -- the same reasoning
that allows `skip_reason` above.

## Aggregating: `max by`, never `sum`

Metrics prefixed `syrus_global_` are **one fact about the whole cluster**, not a
per-pod value. They are sampled once a minute by `SampleGlobalMetricsJob` into the cache, and every pod that serves `/metrics` renders the same numbers.

```promql
max by (queue) (syrus_global_queue_oldest_age_seconds)   # correct
sum by (queue) (syrus_global_queue_oldest_age_seconds)   # wrong: N x the truth
```

Summing across pods multiplies the value by the number of pods scraped. The
`syrus_global_` prefix exists to make that rule legible from the metric name,
but it is not the only signal: `job_state`, `landing_queue_depth`,
`queue_table_rows`, `worker_cpu_percent`, `worker_memory_percent`,
`worker_disk_percent`, `active_agent_runs`, `max_concurrent_agent_runs`, `instance_versions`,
`spawned_processes`, `provider_circuit_state`, `github_rate_limit_remaining`,
`repositories_main_branch_broken_count`, `recurring_job_last_success_seconds`,
`provider_sessions_bytes`, `provider_sessions_rows`,
`escalations_per_landing_ratio`, and `attention_items_open_total` are every
bit as GLOBAL and cache-mediated as the `syrus_global_*` gauges, just declared
without the prefix -- their
`docs/metrics-catalog.md` description ends in `(GLOBAL -- aggregate with max
by...)` instead. Treat that annotation, not the name, as authoritative.

Non-global metrics (`syrus_admission_decisions_total` and every `*_total`
counter/histogram not listed above) are per-process and aggregate normally
with `sum`.

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

`Counter#reconcile!` (the cache-mediated "catch up to this known total" path a
worker-fed sampler uses to bring a counter current on the web process that
actually scrapes -- see `Metrics::LandingSampler`'s class doc) compares and
stores as floats rather than flooring to an integer, so a fractional
cumulative total — a summed dollar cost, say — is not silently truncated on
every tick. A cumulative Run cost counter is one example of this.

## Cardinality

Labels must come from `Syrus::Metrics::TagAllowlist::ALLOWED`, and declaring a
metric with anything else raises at boot. `job_id`, `run_id`, `sha`, `branch`,
repository slugs and user emails are all rejected by name, with an explanation.

One unbounded label turns one metric into millions of series, which is the
standard way to destroy a Prometheus install. It also carries a second job: the
metric store structurally cannot contain a repository name, an issue title, a
prompt or a diff, which is what will let telemetry share aggregates later
without a scrubbing pass to get wrong.

`hostname` and `version` are on the allowlist despite naming a churning
identifier -- see *Fleet* above for why that is a deliberate, narrow
exception rather than a precedent for adding more identifiers casually.

`credential_mode` is on the allowlist for `syrus_github_rate_limit_remaining`
-- a closed, two-value set (`"app"`/`"pat"`, matching `Job#credential_mode`),
not an identifier, so it does not carry the growth risk `repository`/`user`/
`sha` are rejected for.

`problem_code` is on the allowlist for `syrus_attention_items_open_total` for
the same reason -- `Problem::Kind`'s registry is a closed, fixed set of codes
(see `app/models/problem/kind.rb`), not a value that grows with the amount of
work Syrus does.

`unit_type` is on the allowlist for the `throughput` plugin's
`syrus_throughput_landing_units_total` -- a closed two-value set (`"auto_merge"`/
`"merge_train"`), not an identifier.

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

A plugin's `metrics do ... end` block declares through a `while_enabled`
effect (`Syrus::Installer`), which is **sync-on-read** like every other
Installer-backed registry (`Filters::Registry.subjects`,
`SmartFolder.registered_subjects`, `CredentialProbe`'s registries) — nothing
re-applies it on a timer. `MetricsController` calls `Syrus::Installer.sync!`
on its own read path (right before rendering) for exactly this reason: so a
plugin enabled or disabled since this process's last sync renders the correct
metric set on the very next scrape, instead of waiting for some other
subsystem's unrelated read to happen to trigger the sync first.

### Sampling: the shared registry

`Syrus::Metrics.samplers` is the sampling registry. Anything registered here
gets `#sample!` called once a minute by `SampleGlobalMetricsJob` (the shared
control-plane tick every core sampler already uses) and `#refresh_gauges!`
called from the `/metrics` scrape path (`MetricsController#refresh_global_gauges`).
Both of those call sites iterate the registry generically — **adding a new
sampler, core or plugin, requires no change to either file.** Core samplers
(`Metrics::QueueSampler` and friends) call `Syrus::Metrics.register_sampler(self)`
once, at class-body-eval time, right after `declare_metrics!`.

**A global metric that a worker-side event feeds still needs a sampler.**
`/metrics` is served by the web role only (see *Scope* above), so a plugin
whose event happens on a worker — a Run finishing, a landing attempt
completing, a nightly prune job computing a total — cannot just call
`increment`/`set` at the event site; that mutation would sit invisible in the
worker's own in-process registry forever, exactly like the core samplers
above. A plugin has two ways to register into the same shared sampling
registry, both declared inside the manifest's `metrics do ... end` block and
both registered/torn down alongside the metric declaration itself (no
separate `tick_interval` + `Callbacks#on_tick` + hand-written sampler class
needed for either):

**The default: a declarative sampled gauge.** For the common case — read one
aggregate value on a timer — give `gauge` a block instead of hand-writing a
sampler class:

```ruby
syrus_plugin "git_history" do
  metrics do
    gauge :relay_queue_depth, comment: "Pending bare-clone reads" do
      GitHistory::RelayQueue.depth
    end
  end
end
```

The framework wraps the block in a `Syrus::Metrics::SampledGauge`, registers
it, and handles sampling/caching/refreshing — the plugin author writes one
block and nothing else. This form is untagged (the block returns a single
scalar) and gauge-only (a counter or histogram cannot simply be "set" to a
timer-read value — see "Counters never reset" below); reach for the escape
hatch below when either of those doesn't fit.

**The escape hatch: a full sampler class**, for several gauges computed off
one query pass (`Metrics::QueueSampler#collect` is the canonical core
example — six gauges, one query) or a counter/histogram that needs
cursor-based cumulative logic (the `spending_insights` and `throughput`
plugins' own docs work through that case: a cursor over a `finished_at`-style
column, folded into a cumulative total exactly once per event). The class
must implement `.sample!` and `.refresh_gauges!`, the same interface a core
sampler implements, and registers with `sampler`:

```ruby
metrics do
  counter :relay_requests_total, tags: %i[outcome], comment: "Bare-clone reads served"
  sampler GitHistory::MetricsSampler
end
```

Both forms register through the same `Syrus::Metrics.register_sampler`/
`unregister_sampler` calls, made from the manifest `metrics` block's own
`while_enabled` effect (see `Syrus::PluginApi::Definition#metrics`) — so a
disabled plugin's sampler stops sampling and its gauge goes absent on the
next scrape, the same `while_enabled` semantics every other plugin metric
follows, not stale or frozen at its last value.

`Syrus::Plugin::Callbacks#on_metrics_scrape` (called for every enabled,
healthy plugin's `:callbacks` provider from the `/metrics` scrape path,
independent of the sampler registry above) still exists as a lower-level
escape hatch for the rare case that doesn't fit "sample on a timer, refresh
on scrape" at all — but no bundled plugin uses it for metrics anymore, and
reaching for `sampler`/a sampled `gauge` block should be the default over
hand-rolling `tick_interval` + `on_tick` + `on_metrics_scrape` yourself.

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
