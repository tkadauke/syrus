# Multi-worker architecture


Syrus can run more than one worker pod. Per-Job concurrency is enforced with a
DB-backed SolidQueue semaphore (`RunJob` keyed on `job:<id>`), and recurring
pollers/reapers de-duplicate cluster-wide, so most of the system is already
safe across pods. Running workers on more than one node additionally needs the
queue split below; a few behaviors are specific to multi-worker after that.

Search schema is not part of the primary MySQL schema. It lives in
`db/search_migrate` and is applied to the local SQLite search database by
`bin/rails syrus:prepare_search`. Container boot runs this task before web and
worker processes start; local `bin/setup` runs it after `db:prepare`. The task
is idempotent and also verifies the known FTS virtual tables after migration, so
a recorded-but-missing table is recreated on the next deploy. For tables backed
by a durable primary-DB source of truth (`operational_log_fts`,
`browser_error_fts` — see `SyrusSearchDatabaseTasks::REBUILD_HOOKS`), that
(re)creation also replays recent primary-DB rows back into the fresh table, so
a node that loses its local search volume (node-local `hostPath` eviction,
fresh PVC, wiped disk) doesn't sit permanently empty until enough new events
happen to trickle back in through live indexing — it self-heals to the current
retention window on the very next boot. New search/FTS tables must be added
under `db/search_migrate`; if they are required even when an older schema
version was recorded, add them to the task's required-table verification list
too.

The repeatable **Rebuild search database** maintenance task tracks content
versions independently for chats, Jobs, Epics, operational logs, and enabled
plugin search sources. Its persisted rebuild plan shows the current and target
version plus whether each selected source needs a version rebuild, missing
schema, or an integrity repair. A content-version change rebuilds only that
source; sources whose first version matches an existing table are initialized
in place and still receive their normal missing-row integrity check.

Boot-time replay only covers the moment the table is (re)created. A process
that never consumes `indexing` — a compute-tier worker in a split
home/compute deployment, or a per-Run MCP sidecar spawned as its subprocess —
gets that one seed at container boot and then nothing further, since
`IndexOperationalLogEventsJob` never runs there. Left alone, the seed
eventually ages out of `OperationalLogEvent::RETENTION` and every search on
that host silently returns zero rows despite the primary DB still filling up.
`OperationalLogIndex.search` guards against this at query time instead of
requiring an operator to notice: `ensure_fresh!` compares the local table's
newest `occurred_at` against the primary DB's actual latest event (at most
once per `FRESHNESS_CHECK_INTERVAL`, 2 minutes) and calls
`OperationalLogIndex.rebuild!` when the gap exceeds `STALE_AFTER` (5 minutes),
so a stale mirror repairs itself on the next `read_syrus_logs` /
`search_syrus_logs` call rather than staying empty until the pod restarts.

### Bounding background I/O on the home worker

`chat` shares the home worker's process (and local disk) with `cleanup`, which
runs `WorkflowWorkspacePruneJob`'s `chat_workspace_sweep` on a recurring
2-hour tick. That sweep sizes and reclaims idle/over-budget Coding-Mode
checkouts (`ChatWorkspace.reclaim_idle_coding_checkouts!` /
`.reclaim_coding_over_budget!`) — each a multi-gigabyte tree, so sizing one
means a `du -sk` treewalk and reclaiming one adds a git backup push plus an
`rm -rf`. Left unbounded, a sweep touching many checkouts back-to-back can
saturate the shared disk long enough to stall an unrelated small write
elsewhere in the same pod (a live chat turn's agent-home config write, a
`ChatWorkspacePrepareJob` dependency install) — the disk doesn't know or care
which thread issued which I/O, only per-pod thread counts separate them.

Two mitigations, both in `ChatWorkspace`:

- **Low I/O/CPU priority.** `du_bytes` and the maintenance-triggered deletes
  (`prune_idle!`, `reclaim_coding_checkout!`, `sweep_orphans!`) shell out
  through `Syrus::LowPriorityIo.wrap`, which prefixes the command with
  `ionice -c3` (idle I/O class) and `nice -n 19` when available, falling back
  to the bare command otherwise. This never runs on a path a live chat turn
  is synchronously waiting on (`ensure_coding_checkout!`,
  `restore_coding_checkout!`) — only on background-sweep-triggered work, so a
  waiting user is never the one who gets deprioritized.
- **Bounded, paced batches.** `ChatWorkspace::MAINTENANCE_SWEEP_BATCH_LIMIT`
  caps how many *evictions* (a git backup push plus an `rm -rf` of a
  multi-gigabyte tree — the expensive tier) one sweep tick performs in
  `prune_idle!`, `reclaim_idle_coding_checkouts!`, `sweep_orphans!`, and the
  eviction loop of `reclaim_coding_over_budget!`; a no-op skip for a checkout
  that isn't actually on this node's disk doesn't count against the cap or
  get paced. `MAINTENANCE_SWEEP_PACE` sleeps briefly between each heavy
  operation, including every individual `du -sk` sizing call. The sizing pass
  in `reclaim_coding_over_budget!` (one `du` per retained checkout, needed to
  compute an accurate total before deciding whether the node is over budget)
  is deliberately paced but **not** count-capped — capping it could
  under-count the total and mask a real over-budget node — so a sweep with a
  very large number of retained checkouts still has an unbounded number of
  (individually cheap, low-priority, paced) sizing calls in its sizing phase.
  Anything left over on the eviction side is picked up on the next scheduled
  tick rather than draining the whole backlog in one burst.
  `chat_workspace_sweep` wraps the whole sweep in a
  `PerformanceLogging.phase("chat_workspace.sweep", ...)` call so a slow
  sweep surfaces in the same phase-drilldown diagnostics as any other
  performance regression. It also records drill-down phases for each
  maintenance tier: `chat_workspace.prune_idle`,
  `chat_workspace.reclaim_idle_coding_checkouts`,
  `chat_workspace.reclaim_coding_over_budget`, and
  `chat_workspace.sweep_orphans`. The aggregate and drill-down phases request
  host-pressure capture, so slow events include bounded data-root and IO
  pressure metadata alongside the sweep counts/bytes reclaimed. That makes it
  clear whether a slow tick came from idle workspace deletion, coding checkout
  backup/removal, the over-budget sizing pass, orphan cleanup, or local disk
  pressure.

## Git History relay pinning

`RepositoryBareClone#sync!` only ever runs from `PollMergeStateJob` /
`PollPullRequestJob` / `LandingQueueRecheck`, all of which are processed on the
`polling` queue — i.e. today, always the home worker. All three reach it only
through `CommitsBehindCalculator`, which asks the `repository_content_provider`
chain for numeric divergence first and falls back to the bare clone only when
no provider can answer (see `plugins.md`); the polling queue's bare-clone I/O
is now the exception path, not the common one, but the pod-affinity
requirement below is unchanged since the fallback can still fire on every
poll tick when no divergence-capable provider is enabled. `PollMergeStateJob`
gates its own call to `sync!` further: it runs the cheap GitHub-only refreshes
first (mergeability straight off the already-fetched PR payload, terminal
merged/closed checks), and only reaches the ancestry/commits-behind fetch once
the Job is actionable (PR open, Syrus controls the head, the Job itself hasn't
closed) *and* the PR's head/base shas moved since the last check — the
distance between two unchanged commits can't have changed, so a repeat poll
with nothing new skips the fetch entirely. `GithubPollingBudget` layers a
second gate on top, at the polling-cadence level: merge-state polling only
treats `landing`/`approved` Jobs as full-cadence-urgent, so `running`/
`failed`/`blocked_by_epic`/other non-landing Jobs fall back to the
recent-update fast path plus a low-frequency rotation slot — still frequent
enough to notice an externally merged/closed PR, since Syrus has no inbound
GitHub callbacks. `GitHistory::RelayServer`
(the internal-only HTTP server that answers the Git History tab's bare-clone
reads for `Api::V1::App::GitHistoryController`, since web pods don't mount
`$SYRUS_DATA_ROOT`) is only ever booted on a process where
`SyrusVersion.role == "worker"`, and `RelayServer.ensure_running!` additionally
gates on `WorkerQueueTopology.consumes?("polling")` — this process's own
resolved queue config, not just "some worker process" — so it starts
specifically on the pod(s) that will actually sync bare clones, not on every
worker-role pod. This used to be a coarser `role == "worker"`-only check,
which meant every compute-tier pod in a split deployment started a relay that
was reachable but could never answer `available: true` for anything — a bug
that shipped invisibly because a misrouted-but-reachable relay looks
identical to a healthy one that hasn't synced yet.
`GitHistory::RelayServer` still has the same shape as the `chat` pinning
above in one respect: nothing enforces which *specific* pod within the
`polling`-consuming tier holds a given repository's synced clone the way
`ChatSession#coding_relay_address` does for coding checkouts. As long as
`polling` (and therefore bare-clone syncing) stays on a single home worker,
the relay serving that same worker process is correct by construction. If
`polling` is ever split across more than one pod, `GitHistory::RelayServer`
must run on — and `GitHistoryController` must be able to reach — every pod
that might hold a given repository's synced clone, or Git History reads can
silently serve stale or inconsistent history depending on which pod answers.
`PollingQueueCoverageCheckJob` (recurring, every 5 minutes) logs a structured
error if *no* live worker process anywhere reports consuming `polling` at
all — the backstop for a queue-config split that omits `polling` from every
tier, which would otherwise degrade exactly as silently as the bug above.

`PollMergeStateJob` fans out once per tracked Job, so several Jobs sharing a
repository land in the same `PollAllMergeStatesJob` tick. Rather than each one
calling `RepositoryBareClone#sync!` independently, `RepositoryCommitDistance`
sits in front of it: the `(repository, base_sha, head_sha)` divergence is
cached directly (that tuple is immutable once computed), and the underlying
`sync!` fetch is coalesced per repository behind a bounded freshness window
(`RepositoryCommitDistance::REFRESH_FRESHNESS_WINDOW`, kept just under
`PollAllMergeStatesJob`'s 5-minute cadence) guarded by an exclusive file lock
next to that repository's bare-clone path. The lock lives under
`$SYRUS_DATA_ROOT`, so it coalesces correctly whether concurrent pollers land
on the same process, the same pod, or (if `polling` is ever split) different
pods sharing that mounted volume — a caller that arrives mid-refresh blocks on
the lock instead of starting a second full-ref fetch. `syrus_repository_commit_distance_lookups_total`
(tagged `outcome`: `cache_hit`, `cache_miss`, `refreshed`, `coalesced_wait`)
instruments which path each lookup took.

`SOLID_QUEUE_CONFIG` is a path relative to the Rails root; if it points at a
missing file SolidQueue silently falls back to its *own* built-in default (not
`config/queue.yml`), so set it exactly. **Single-host and docker-compose
deployments (including the desktop apps) do not set `SOLID_QUEUE_CONFIG`** — they
run the full `config/queue.yml`, where one worker consumes every queue. That file
is deliberately kept complete; never trim it to match the split. `bin/check-thread-budget`
validates all three configs against the DB pool, and `spec/config/queue_partitioning_spec.rb`
guards that the split stays a clean partition of `queue.yml`'s queues.

Two things are specific to multi-worker:


Distributed immutable-source graders are not tied to the rejecting worker's
workspace. For `local_worker_pressure_critical` and
`host_resource_semaphore_busy`, Syrus checks live workers that satisfy the
grader's declared capabilities. When one has fresh healthy telemetry and
compute headroom, the same queued Run is dispatched immediately to that
worker's hostname-specific `worker-<hostname>` queue with its original
priority. This queue is distinct from `resume-<storage-key>` and therefore
still targets one worker when several workers share an RWX data root. The
admission artifact names
the rejecting worker and reason, alternatives considered, selected queue, and
worker. Rejected workers are excluded within a routing cycle; if every eligible
worker is pressured, Syrus clears the bounded exclusion set and uses increasing
backoff instead of bouncing the Run continuously between hosts.

For `host_resource_semaphore_busy`, the Job page's queued-Run banner and the
artifact's `resource_guard_binding_terms` identify whether compute units,
reserved memory, measured memory, or more than one term bound admission. Compare
`active_compute_units + candidate_compute_units` with `host_compute_capacity`,
and compare `active_reserved_memory_bytes + candidate_reserved_memory_bytes`
and `current_memory_bytes + candidate_reserved_memory_bytes` with
`host_memory_effective_budget_bytes`. The effective budget is
`host_memory_budget_bytes - grader_memory_reserve_bytes`; the reserve is zero
for non-grader candidates. A host with no active guarded Run ignores these soft
memory estimates; only critical sampled memory, disk, or CPU pressure can defer
the lone candidate.

Agentic and grader fallback memory reservation is the effective memory limit
divided by host compute capacity, then multiplied by the Run's capacity units.
Deterministic compute such as `prepare` instead uses command-attributed p90
memory when a matching resource profile exists and a conservative fallback
bounded at 1 GiB when it does not. Active reservations use the same evidence
per Run, so several low-demand deterministic commands no longer each claim a
full CPU-derived memory unit. Measured container working-set usage remains an
independent binding term, and command evidence above the fallback is not
clamped; either can still defer work that presents a credible OOM risk.

The artifact records `candidate_memory_evidence_source` and tallies
`active_memory_evidence_sources`; the queued-Run banner identifies the
candidate source alongside measured usage, active and candidate reservations,
and the effective budget. `SYRUS_WORKER_CPU_LIMIT` continues to control compute
parallelism and the agentic/grader fallback, but no longer inflates a
low-demand deterministic command's memory reservation. Operators should inspect
the evidence source before changing CPU limits: increase the container memory
limit for genuine measured or command-attributed pressure, while a repeated
bounded fallback indicates that more command profile samples would sharpen the
estimate.
The Job detail payload uses that `run_id` to attach the admission block only to
the Step that owns the queued Run. Worker-slot admission artifacts use their
`step_id` the same way. This keeps one waiting distributed grader from making
its ready or running siblings, or the whole Workflow, appear paused.

Worker-died auto-retries add a pre-dispatch guard before they create a
replacement Run. If the failed Run's `workflows.worker_hostname` still has a
fresh critical health sample, `AutoRetryJob` leaves the retry attempt pending,
records `failed_worker_hostname`, the failed worker's health level/reasons,
sample timestamp, deferral timestamp, and a `failed_worker_retry_context`
payload with reason `failed_worker_host_still_critical`, then re-enqueues the
same `AutoRetryAttempt`. This prevents repeated landing-fix or grader
replacements from being immediately admitted back onto a host that is still
critically pressured.

Scheduling a `worker_died` retry is idempotent per failed Run: once any
unskipped `AutoRetryAttempt` exists for a given `(run, retry_kind)` pair, no
further attempt is scheduled for it, even after the first is marked performed.
See `docs/engineering/architecture/work_engine_reconciler.md` for why more than one issue classifier can
otherwise propose the same repair for one Run and how that used to slip a
duplicate attempt past the "retry already pending" guard.

## Per-worker workspace pruning

A workspace lives on the data root that ran the workflow, so a worker on a
different local disk can't clean it. Two safeguards make pruning storage-local:

- `WorkflowWorkspace.cleanup_for` skips a workflow only when another live
  storage-affinity queue still owns it, so a prune pass can't false-stamp
  `cleaned_up_at` on a workspace that's still on another data root. It cleans
  normally when the recorded storage key is this data root, is blank (legacy /
  single-worker), or has no live queue consumer.
- `WorkflowWorkspacePruneJob` (recurring) is a coordinator: it runs the
  cluster-wide DB/branch and chat sweeps once, then **fans the local filesystem
  sweep out to every live storage-affinity queue**. With no tracked resume
  queues (single-host / dev) it sweeps the local disk directly.

## Worker host health history

Worker heartbeats also write a bounded historical row to
`worker_host_health_samples` for each worker host observation. The table is wide
by design: hostname, role, version, observation time, CPU usage, load averages,
memory usage, `SYRUS_DATA_ROOT` usage, Linux CPU pressure, Linux IO pressure,
and a small `raw_metrics` JSON escape hatch for source/path metadata or future
platform-specific fields.

Sampling is best-effort and cheap. The heartbeat reuses the same `df` snapshot
that updates `InstanceVersion`, reads lightweight Linux files under `/proc`, and
swallows sampler failures so worker liveness is never destabilized by metrics.
Rows are retained for `WorkerHostHealthSample::RETAIN_AFTER` (7 days, matching
`RunHealthSnapshot::RETAIN_AFTER`) and pruned daily by
the `worker_host_health_sample` registry policy.

The heartbeat Thread is a single per-process code path: if it never starts
(role/env misconfigured on that process) or dies, that host's samples go
silent with no direct signal until `WorkflowAdmissionBudget` eventually falls
back to its neutral "absent" telemetry reading (see the admission-control
section below). Two recurring Solid Queue jobs backstop this:
`WorkerHostHealthSampleJob` (`sample_worker_host_health`, every minute, queue
`cleanup`) independently records a sample for whichever worker process
executes it, using Solid Queue's normal job-execution threads rather than the
heartbeat Thread — so a dead/never-started heartbeat on that same process
still gets sampled here, and it self-heals the process's `InstanceVersion` row
if registration itself never happened. `WorkerHostHealthTelemetryCheckJob`
(`check_worker_host_health_telemetry_gap`, every 5 minutes, queue `cleanup`)
compares live (fresh-heartbeat) worker `InstanceVersion` hostnames against
hosts with a `WorkerHostHealthSample` in the last 5 minutes and logs a warning
naming any host with a live heartbeat but no recent sample, so the gap is
visible immediately instead of only manifesting days later as a start-blocked
Workflow. In the single-node/Compose deployment (`config/queue.yml`, one
worker consuming every queue) this fully covers that worker; in a split
multi-node deployment (`config/queue.home.yml` /
`config/queue.compute.yml`) the `cleanup` queue is home-tier only, so these
two jobs sample and audit the home pod but not compute pods — compute pods
still rely primarily on their own heartbeat Thread, with the telemetry-gap
warning as the visible signal if that thread goes dark.
The current admin overview, `/api/v1/admin/version`, and the admin queue
workers payload include worker health snapshots alongside the existing
data-root disk fields. Freshness follows `InstanceVersion` worker heartbeat
semantics: the current worker lists only include workers with a fresh heartbeat,
so deploy-era hostnames fall out of the active fleet view after the stale
threshold even before their historical metrics expire. The Workers tab
(`/admin/queue/workers`) renders that payload inline as a per-host chart
dashboard using a shorter 2-hour default lookback for page load. Operators can
switch quick ranges (`30m`, `1h`, `2h`, `6h`, `24h`) or enter explicit start/end
times; the tab persists those values in the URL and forwards them to the
worker-health `since`, `until`, and minute-bucket window params. Charts cover
CPU, load, memory, data-root disk usage, CPU pressure, and IO pressure, with
compact exact-value tables kept as drilldown. Hosts that have samples in the
selected range but no fresh worker heartbeat remain chartable and are labeled
historical instead of current. Solid Queue process rows in the Workers tab use
the same heartbeat threshold: stale worker process rows are filtered out of the
primary worker table and labeled stale in the full process inventory.
Disk alerts still come from the most-full worker's `InstanceVersion` reading so
existing alert behavior is unchanged. For deeper inspection,
`/api/v1/admin/worker_health` and `/api/v1/app/admin/worker_health` return live
worker status plus compact 15m/1h/6h/24h summaries, recent samples, and bounded
minute-resolution buckets. By default each host includes one bucket per minute
for the last hour, ending at `until`; callers can increase that bounded minute
window with `minute_bucket_window_minutes` up to 24 hours. Each bucket includes
the minute timestamp, sample count, warning/critical counts, and max/avg
summaries for CPU, load, memory, data-root disk, CPU pressure, and IO pressure.
The payload can be filtered with `hostname`, `since`, `until`,
`sample_limit_per_host`, and `minute_bucket_window_minutes`.

Admin chat agents can call `read_worker_health` for the same payload. Use it
when diagnosing pod-local pressure, recurring worker warnings, or failure
patterns that may correlate with CPU, memory, disk, or IO pressure.

Workflow and insight agents can call `read_run_worker_health` to correlate a
specific Run with retained host samples. The tool uses
`workflows.worker_hostname`, the Run's start/finish timestamps, related
`SpawnedProcess` host metadata, and the Step kind to return a compact pressure
summary plus optional raw samples. For `grader` and `preflight_grader` Runs,
the payload also includes durable command spans for phases such as `bundle
check`, `bundle install`, `db:test:prepare`, and `rspec`; each span carries its
own hostname, timing window, pressure summary, sample count, and retention
flags. Command span sample windows are bounded by the earliest available
`command_span.finished_at`, owning `spawned_process.finished_at`,
`run.finished_at`, or query time, and unfinished spans report
`effective_finished_at`/`effective_duration_s` plus `truncated`,
`truncated_by`, and `orphaned` flags when that effective window was inferred
from owner terminal state. The Job detail payload also includes a recent-run
aggregate, and each serialized Run includes its own compact correlation. Runs
or spans older than
`WorkerHostHealthSample::RETAIN_AFTER` are marked `retention_limited`; missing
hostnames or samples return `pressure.level: "unknown"` rather than treating
the interval as healthy.

Run completion also writes one durable `run_resource_summary` row per Run. The
summary intentionally separates host-correlated metrics from command-attributed
metrics: `host_usage_*` and `host_pressure_*` fields describe ambient worker
conditions during the Run window, while `process_*` fields describe resource
usage attributed to spawned workflow commands when process-group accounting is
available. Active Runs can refresh the row best-effort from the latest persisted
spawned-process attribution payloads. When process attribution is unavailable,
the row keeps `process_resource_fallback: true`, low confidence, and an explicit
unavailable reason so profilers and schedulers do not confuse host pressure with
command-owned CPU, RSS, or IO usage.

Raw `worker_host_health_samples` keep their short retention window. Durable
`run_resource_summaries` are detailed operational telemetry and are pruned after
30 days by the `run_resource_summary` registry policy.

## Workflow Step Resource Profiles

Completed Runs persist one `run_resource_summary` row with the Run timing
window, retained host-pressure correlation, command-span counts, and any
process-owned command metrics captured on spans. Detailed summaries are pruned
after 30 days.

`WorkflowStepResourceProfileRefreshJob` rebuilds
`workflow_step_resource_profiles` hourly from non-retention-limited summaries
observed in the last 180 days. Profiles are keyed by repository, agent
provider, trigger kind, step kind, grader name when the step is a grader, and
job kind. Aggregates store p50/p90/p99 duration, timeout/failure rates, and two
resource families:

- `process_attributed_*` values come only from command-span metadata that is
  owned by the process, such as CPU seconds, CPU percent, RSS/memory bytes, or
  IO bytes. Command duration alone is retained as timing evidence but does not
  make CPU, memory, or IO attribution process-backed.
- `host_pressure_*` values come from worker host health samples correlated to
  the Run window. They are useful fallback evidence but remain host-correlated,
  not proof that the step itself consumed those resources.

Prediction confidence follows the sample thresholds on the best available
resource basis: fewer than 10 samples uses conservative defaults, 10-29 permits
soft prediction, 30+ permits normal admission decisions, and 100+ permits tight
confidence. Resource-fit prediction prefers process-attributed metrics once
they have enough samples; otherwise it falls back to host-correlated pressure
when available, then conservative defaults. `attribution_quality` records
whether a profile is process-attributed, host-correlated, mixed, or defaults
only so admin surfaces can audit top command consumers without
conflating host pressure with process-owned cost.


Broad predictive gates were removed because they measured the wrong thing.
`p90_cpu_pressure` and `p90_memory_used_percent` recorded the *host's ambient
state* while a step ran, not the step's own demand — so
`mergeability_preflight`, a 52-second GitHub API call using 2.7% CPU, profiled
at 84.1 cpu_pressure and 75.9% memory, and was rationed as if it were an agent.
`p90_process_attributed_cpu_percent` is the real per-process figure, on a
different scale again (0.3 for `prepare`, 230 for a multi-core rspec run).
Three scales were being compared against budgets as if they were one. The
remaining grader guard deliberately uses only command-attributed predictions
and only under local warning pressure.

The result was self-reinforcing: ambient readings rise with load, so the
throttle tightened exactly when it should have relaxed. Production sat at ~18%
agent utilisation with hosts reporting 88% CPU headroom, 88% of admissions came
through the minimum-progress floor rather than the budget, and one landing step
deferred 73 times in 36 minutes.

Two guard rails worth keeping in mind when changing this:

- The per-repository cap (`MAX_REPOSITORY_ACTIVE_WORKFLOWS`) is **not** a gate.
  It only ever fired alongside a predicted-cost signal, so its value was never
  tested against reality; applying it unconditionally caps a repository at two
  concurrent workflows, where production routinely runs 16-25. Per-user
  fairness belongs to `Admission::FairShare`.
- The minimum-progress floor is an anti-stall backstop, not a path. If most
  admissions are arriving through it, the gate in front of it is refusing work
  it should be admitting — that is exactly what the predictive model did.

## How Workflow Admission Pressure Was Counted (historical)

Three rules, and getting any of them wrong throttles a fleet that is mostly
idle:

- **A workflow's pressure is its peak step, not the sum of its steps.** Steps
  run sequentially, so a workflow contributes the load of exactly one of them
  at any instant. Duration is still summed — that genuinely is how long the
  whole workflow takes, and it is what `high_cost?` judges.
- **Only workflows with a *running* Run count as load.** A workflow whose next
  Run is merely queued is consuming nothing. Counting it creates a feedback
  loop, because work admission has just delayed comes straight back as
  pressure justifying the next delay.
- **The budget is the fleet's, not one host's.** CPU and IO are summed across
  concurrently active workflows, so the ceiling is `CPU_BUDGET ×
  healthy_worker_count`. Memory is a max across workflows, so it stays on a
  single host's scale.

Before these were right, per-step pressures were summed within a workflow
(~480 for one workflow), summed again across active workflows (~9,100), and
compared against 100.0 — so `over_budget?` was true whenever anything was
running. Production sat at roughly 18% agent utilisation with hosts 87% idle,
and 88% of admissions only got through on the minimum-progress floor, which
made the effective concurrency limit `healthy_worker_count` rather than the
configured budget. If admissions are overwhelmingly `minimum_progress_floor`
rather than `within_budget`, that is the symptom to look for.


Every admission decision also records `pressure.host.telemetry_state` (and a
copy under `details.telemetry_state`): `"present"` when fresh
`WorkerHostHealthSample` rows landed inside the sampling window, `"stale"` when
samples exist but none are recent (a monitoring gap, e.g. a missed heartbeat
tick), or `"absent"` when no worker host health samples have ever been
recorded (e.g. the per-worker heartbeat thread never started). A `"stale"` or
`"absent"` state reports an explicit, documented neutral/zero-pressure host
reading — full headroom, not a synthesized worst case — so a total telemetry
outage cannot masquerade as maxed-out hosts. It only changes what the
host-pressure gate itself can see; profile prediction diagnostics are computed
separately from host telemetry. Admin and dashboard surfaces reading
`start_blocked_details` or `workflow_admission_decision` should treat
`telemetry_state` as the source of truth for "no data" versus "data says busy"
rather than inferring it from a 0% pressure reading.

Fresh host samples also carry a locality summary under
`pressure.host.locality`, with flattened copies in `details` for the admin
page: `pressured_worker_storage_keys`,
`healthy_alternative_worker_storage_keys`, `worker_pressure_scope`, and
`worker_pressure_localized`. When high pressure is isolated to one worker
storage key and other sampled keys are healthy, Syrus records
`localized_worker_host_pressure_high` instead of presenting the situation as
whole-pool `worker_host_pressure_high`; per-host Run admission still refuses
compute work claimed by a critical worker. Operators should use the listed
storage key plus hostnames to repair the unhealthy worker and the healthy
alternative list to confirm the pool is not broadly saturated.


## Reading admission inputs from the admin API

- `GET /api/v1/admin/queue/workers` reports `admission_capacity` per worker:
  `effective_cpu_count`, `cpu_source` (`cgroup_v2_quota`, `cgroup_v1_quota`,
  `env_override`, or `undetectable_fallback`), `cpu_fallback_in_effect`,
  `host_compute_capacity`, `agentic_capacity_units`, `agentic_runs_per_host`,
  `grader_runs_per_host`, `agentic_reserved_units`, and memory limit, budget
  and reserve. Workers publish it with their heartbeat (it is computed from
  their own cgroup), so it can lag a restart by one heartbeat.
- `GET /api/v1/admin/runs` and `/runs/:run_id/artifacts` carry `host_admission`
  for a Run that is still queued: the latest deferral (reason, binding terms,
  compute and memory evidence). It is null once the Run starts or finishes.
- `GET /api/v1/admin/settings` returns every non-secret AppSetting with its
  value and registry metadata, including `max_concurrent_agent_runs`.
