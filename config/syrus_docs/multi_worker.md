# Multi-worker operation

Syrus can run more than one worker pod. Per-Job concurrency is enforced with a
DB-backed SolidQueue semaphore (`RunJob` keyed on `job:<id>`), and recurring
pollers/reapers de-duplicate cluster-wide, so most of the system is already
safe across pods. Running workers on more than one node additionally needs the
queue split below; a few behaviors are specific to multi-worker after that.

## Spreading workers across nodes (queue partitioning)

The search index is SQLite FTS5 on a single-node RWO volume, so the queues that
touch it can't spread. To run agent compute on multiple nodes anyway, split the
queues across two worker configs and select one per pod with the
`SOLID_QUEUE_CONFIG` env var:

| Config | Queues | Where |
| --- | --- | --- |
| `config/queue.home.yml` | `chat`, `videos`, `control_plane`, `polling`, `indexing`, `cleanup`, `low_priority_maintenance` (+ its `resume-<worker-storage-key>`) | one pod, on the node holding the search PVC / with the web pods |
| `config/queue.compute.yml` | `runs`, `merges` (+ its `resume-<worker-storage-key>`) | one pod per worker node; local disk, no search mount |

- **The home worker** runs everything bound to the single-node search index or
  co-located with it: `control_plane`, `polling`, `indexing` (search
  **writes**), `cleanup`, `low_priority_maintenance`, `chat` (search **reads**
  via the `search_chats` MCP tool), and `videos`. It is the tier that schedules
  recurring tasks — leave `SOLID_QUEUE_SKIP_RECURRING` unset here.
- **The compute worker** runs the heavy, search-free queues — `runs`
  (implementation, response, grader, and `main_grader` RunJobs) and `merges`
  (landing / rebase) — which enqueue their search updates onto `indexing` rather
  than touching the index directly. Spread it one-per-node on fast local disk.
  Set `SOLID_QUEUE_SKIP_RECURRING=1` so only the home worker schedules recurring
  jobs.
- Both configs consume the current data root's `resume-<worker-storage-key>`
  queue, so retry-from-failed-step affinity (below) works on whichever worker
  can see the workspace.

**The home worker MUST be a single pod** (`replicas: 1`, `strategy: Recreate`).
Chat workspaces (`ChatWorkspace`, at
`$SYRUS_DATA_ROOT/chat-workspaces/<chat_session_id>`) are local-disk and
long-lived, and — unlike Workflows — chat has **no** pod-affinity mechanism.
`chat_sessions` records no `worker_hostname`; while a coding checkout is on
disk, `ensure_coding_checkout!` returns that local checkout instead of re-cloning
on another pod. A chat session's turns therefore MUST all land on the same pod,
which holds only because exactly one pod consumes `chat`. Never put `chat` on
the compute DaemonSet, and never scale the home worker past one replica. (If the
chat tier ever needs to scale, chat first needs its own storage-affinity queue
keyed off `chat_sessions.workspace_path` or equivalent durable workspace owner.)
Coding-mode **handoff** is exempt: `submit_coding_changes` captures the current
HEAD to an immutable handoff branch after confirmation, and
`complete_implement_step` uses the pushed Job branch, so the resulting
`coding_handoff` Workflow clones fresh from GitHub and runs safely on any
compute pod.

`SOLID_QUEUE_CONFIG` is a path relative to the Rails root; if it points at a
missing file SolidQueue silently falls back to its *own* built-in default (not
`config/queue.yml`), so set it exactly. **Single-host and docker-compose
deployments (including the desktop apps) do not set `SOLID_QUEUE_CONFIG`** — they
run the full `config/queue.yml`, where one worker consumes every queue. That file
is deliberately kept complete; never trim it to match the split. `bin/check-thread-budget`
validates all three configs against the DB pool, and `spec/config/queue_partitioning_spec.rb`
guards that the split stays a clean partition of `queue.yml`'s queues.

Two things are specific to multi-worker:

## Global agent-concurrency cap

`JOB_CONCURRENCY` caps agent Runs **per pod**, so total agent concurrency scales
with pod count. `AppSetting.max_concurrent_agent_runs` (admin-configurable,
`0` = unlimited) is a **cluster-wide** cap enforced by `RunJob`: if too many
agent (`:runs`-queue) Runs are already executing across all pods, a new one is
deferred and re-enqueued. Main-branch grader Runs are on `:runs` and are counted
too; landing/merge Runs are not counted. See `AppSetting` reference.

## Retry-from-failed-step storage affinity

Each Job keeps at most one on-disk workspace. On local-disk-per-worker
deployments that workspace lives on one worker data root, so a "Retry from
failed step" (`Workflow#reopen`) must resume on a worker that can see that same
data root.

- On first boot against a data root, `WorkerStorageIdentity` creates a durable
  id file at `$SYRUS_DATA_ROOT/.syrus-worker-storage-id` (or `~/.syrus` when
  `SYRUS_DATA_ROOT` is unset).
- Each worker consumes `resume-<worker-storage-key>` for that durable id
  (declared in `config/queue*.yml`).
- When a `RunJob` runs a workflow it records both diagnostics hostname
  (`workflows.worker_hostname`) and routing key
  (`workflows.worker_storage_key`).
- On reopen / post-crash re-enqueue, `Run#enqueue_run_job` routes to
  `resume-<worker-storage-key>` only when a fresh Solid Queue worker advertises
  that queue. If no worker currently consumes it — node gone, storage gone, or
  old deployment without the queue — routing falls back to the normal workflow
  queue and recovery relies on durable transcript rehydration or fresh retry.

This needs no deployment-specific node naming. With node-local `hostPath`, each
node gets a different storage key that survives pod replacement on that node.
With a shared RWX volume, all workers see the same id and safely share one
resume queue. With per-pod ephemeral storage, each pod gets its own id and
affinity lasts only as long as that storage does.

`worker_hostname` remains useful for diagnostics, process ownership, and worker
health correlation, but it is not the resume-routing key.

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

## Per-worker disk health

Each worker fills its own data volume independently, so disk health is per-pod.
Worker pods stamp their own `SYRUS_DATA_ROOT` usage onto their `InstanceVersion`
row every heartbeat (`df`, worker role only — web pods don't mount the volume).
The "Worker data volume usage" banner and the admin overview surface the
**most-full** worker (`InstanceVersion.worst_data_root`), naming the pod, and
fall back to the single cached snapshot on single-worker / dev. The banner's
remediation copy branches on deployment: single-host Docker (Compose / the
desktop apps, detected via `SYRUS_SQLITE`) gets `docker image prune` guidance
because the volume shares the Docker host's disk; K8s gets per-pod workspace and
volume-resize guidance instead.

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
`WorkerHostHealthSamplePruneJob`.

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
flags. The Job detail payload also includes a recent-run aggregate, and each
serialized Run includes its own compact correlation. Runs or spans older than
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
30 days by `RunResourceSummaryPruneJob`.

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
only so Admin and Supervisor surfaces can audit top command consumers without
conflating host pressure with process-owned cost.

## Workflow Admission Control Kill Switch

`AppSetting.workflow_admission_control_enabled` is the global operator kill
switch for the soft workflow admission budget. It defaults to `true`. When an
admin disables it from Admin Settings, `WorkflowAdmissionBudget` still blocks
hard worker memory/disk exhaustion but bypasses soft worker pressure,
conservative/default-only predictions, pending high-cost work, and repository
concurrency throttles. Other start blockers remain outside this switch:
provider circuits, explicit landing pauses, dependency blockers, archived
repositories, missing PRs, and Job readiness checks still apply.

Every disabled admission decision records `admission_control_disabled=true`,
the last changed timestamp/user, and the `bypassed_gates` list in the Workflow
admission artifact. Admin changes are audited as `AdminAction` rows
(`disable_workflow_admission_control` / `enable_workflow_admission_control`),
and toggling either direction wakes admission-delayed Workflows plus the
landing queue so existing sleepers are reconsidered promptly.

While admission control is enabled, Syrus also keeps a minimum-progress floor:
at least one admission-controlled workflow may start per healthy worker while
running agentic work is below that floor. This makes soft host pressure and
conservative/default-only predictions throttling signals instead of a total
stop, so landing and merge-train progress cannot starve behind uncertain
estimates. Hard worker memory/disk exhaustion and the non-admission blockers
above still win. Admission artifacts include the healthy worker count, active
agentic run count, floor capacity, whether the floor override was used, and the
soft gates that were present.

Every admission decision also records `pressure.host.telemetry_state` (and a
copy under `details.telemetry_state`): `"present"` when fresh
`WorkerHostHealthSample` rows landed inside the sampling window, `"stale"` when
samples exist but none are recent (a monitoring gap, e.g. a missed heartbeat
tick), or `"absent"` when no worker host health samples have ever been
recorded (e.g. the per-worker heartbeat thread never started). A `"stale"` or
`"absent"` state reports an explicit, documented neutral/zero-pressure host
reading — full headroom, not a synthesized worst case — so a total telemetry
outage cannot masquerade as maxed-out hosts. It only changes what the
host-pressure gate itself can see; step-level `WorkflowStepResourceProfile`
predictions still fall back to `WorkflowStepResourceProfile::CONSERVATIVE_DEFAULTS`
when a profile is genuinely missing, independent of host telemetry
availability. Admin and dashboard surfaces reading `start_blocked_details` or
`workflow_admission_decision` should treat `telemetry_state` as the source of
truth for "no data" versus "data says busy" rather than inferring it from a
0% pressure reading.

`AppSetting.workflow_admission_policy` chooses how far that admission decision
extends:

- `whole_workflow` (default) admits or delays before a Workflow starts. Once a
  Workflow is running, Syrus keeps advancing through normal phase boundaries so
  "In progress" means work is actually expected to continue.
- `phase_aware` preserves the tighter optimizer: Syrus may pause between
  phases when predicted pressure is high. These paused Workflows stay in the
  persisted `running` state but expose an apparent `paused` state in dashboard
  payloads and smart folders until the recheck resumes them.

Both policies still pause in-flight Workflows for hard worker memory or disk
exhaustion. Those pauses write `pause_reason`, `pause_kind`,
`pause_started_at`, `pause_next_check_at`, and `pause_details` artifacts, and a
scheduled admission wakeup can resume them when pressure clears.
`WorkflowPhaseAdmissionJob` retries the next queued step after the backoff.

Manual Job pause is operator-controlled and is not an admission-control signal.
It persists on the Job (`manual_paused`) and takes effect at the next Step
boundary: the current Run finishes, then the dispatcher records
`pause_reason: manual_pause` on the Workflow and does not enqueue another Run.
Manual pauses have no automatic `next_check_at`; only an operator unpause clears
the flag and lets normal admission/dependency/provider checks decide when the
workflow can proceed.
