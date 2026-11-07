# Multi-worker operation

## Worker capability advertisement

Workers advertise normalized execution capabilities on their heartbeat and
worker-health samples. Syrus supports `os`, `arch`, `toolchain`, and `runtime`
capabilities. Operators can override or add advertised capabilities with
`SYRUS_WORKER_CAPABILITIES`, using comma or space separated `dimension:value`
pairs:

```dotenv
SYRUS_WORKER_CAPABILITIES=os:macos,arch:arm64,toolchain:xcode,runtime:ios_simulator
```

Only `os:linux` and `os:macos` are admitted for the OS dimension. `arch`,
`toolchain`, and `runtime` accept normalized tokens such as `arm64`, `xcode`,
and `ios_simulator`. Unknown dimensions and unsupported OS values are ignored
for worker advertisements. Native macOS workers can rely on host probes for
Xcode and simulator runtime advertisements when the tools are installed, or set
them explicitly in the env file when operators want a fixed declaration. The
macOS probes are read-only: they run version and listing commands such as
`sw_vers`, `xcode-select`, `xcodebuild -version`, `xcrun --find xcodebuild`,
and `xcrun simctl list`. They do not mutate keychains, signing state,
simulator contents, or selected devices. Linux k3s and Docker Compose workers
can usually rely on detected `os:linux` and host architecture.

Admin Workers, worker-health payloads, `read_worker_health`, and `read_queue`
include the normalized capability map and probe diagnostics. For iOS-capable
Mac workers those diagnostics include macOS host version and architecture facts,
selected developer directory, Xcode version and build version,
command-line-tool usability, available iOS simulator runtimes, and a bounded
sample of available simulator devices. Each tool probe also reports a status
such as `available`, `not_found`, `not_executable`, `failed`, or `timed_out`,
so a missing executable can be distinguished from a tool that ran and rejected
the probe. Probes inherit the worker's `PATH` but keep the rest of their
environment scrubbed. Historical health samples keep the
capability snapshot that was true when the sample was recorded. `admin_version`
is intentionally limited to the request handler and live instance version
fields.

External worker pools can set `SYRUS_WORKER_POOL_NAME` to a stable
operator-facing name such as `macos-xcode`. Syrus records that value in worker
capability diagnostics on `InstanceVersion` and `WorkerHostHealthSample` rows;
it is descriptive metadata, not a scheduler input. Placement still comes from
advertised capabilities plus the Solid Queue config the process runs.

## Capability-aware Run queues

Runs with the default Linux implementation requirement stay on the broad
`runs` queue. When a mutable workflow or immutable distributed grader records
host requirements for a distinct execution class, Syrus routes the Run to a
capability-specific queue derived from the workflow template's base queue:

- `runs-linux-amd64`, `runs-macos-arm64`
- `merges-linux-amd64`, `merges-macos-arm64`

Queue suffixes use the requested or advertised architecture when present,
falling back to Syrus defaults for the supported OS values: Linux uses the
`linux-amd64` lane and macOS uses the `macos-arm64` lane. Toolchain and runtime
requirements do not create extra queue-name segments; they are checked against
live worker capability metadata before admission and enqueue.

`config/queue.yml` and `config/queue.compute.yml` render their compute queues
from the worker's advertised capabilities. A default Linux worker consumes
`runs`, `runs-linux-amd64`, `merges`, and `merges-linux-amd64`; a macOS worker
advertising `os:macos` consumes the macOS lanes. This keeps scarce native workers from
claiming ordinary Linux work while still documenting every queue Syrus may
select.

Before a workflow phase starts, `StepDispatcher` uses the same queue resolver
as `Run#enqueue_run_job` to check live Solid Queue worker metadata. Pinned
workspace phases such as implementation, response, rebase repair, visual
review, and adversarial review inherit the Workflow's planned primary
capabilities. Immutable distributed grader steps use their target-specific
requirements. Control-plane phases such as grader fanout and collection stay on
the broad `runs` / `merges` queues, so scarce native workers do not claim
orchestration work just because the primary workflow runs on macOS.

The resolver checks capability-specific queues, and also checks broad queues
when explicit Linux requirements are present. If no fresh worker both consumes
the selected queue and advertises compatible capabilities, the Workflow stays queued with
`start_blocked_reason: no_capable_worker`; `start_blocked_details` and
`run_queue_admission_decision` record the selected queue, requirements, and
phase step so operators can see why it is waiting. Those details also include a
compact snapshot of live worker queues, capabilities, probe diagnostics, and
drain state, so an iOS shortage can distinguish "no Mac worker online" from
"Mac worker online but missing an iOS simulator runtime" or "Mac worker is
draining." Syrus schedules a normal phase-admission recheck instead of
creating a Run that would sit on an unconsumed or incompatible queue.

`Run#enqueue_run_job` repeats that check at enqueue time as a backstop. When it
does enqueue, the Workflow appends a `run_queue_decisions` artifact recording
the queue and requirements used for the Run. If live capacity disappears
between admission and enqueue, the Run is failed with
`agent_outcome: no_capable_worker`, a system log line is written, and the
Workflow records a `run_queue_blocked` artifact with the queue and requirement
details.

### Diagnosing a queued Run

The queued-Run banner on a Job's Workflows tab reflects the RunJob's current
Solid Queue state instead of assuming every wait is worker saturation:

- **Waiting for a slot** means a live worker consumes the selected queue and
  all of its advertised threads are occupied.
- **No queue consumer** means the RunJob is ready, but no live worker consumes
  its queue. Check **Admin → Queue → Workers**, especially for a stale
  `resume-<storage-key>` affinity queue.
- **Concurrency blocked** means Solid Queue is holding the RunJob behind the
  per-Job concurrency key. Check the pending queue and retry the Job if the
  earlier work is no longer active.
- **Scheduled** means Solid Queue will make the RunJob ready at the displayed
  future time.
- **Claimed but not started** means a worker process owns the RunJob, but the
  Run record has not transitioned to running yet.
- **No RunJob** means no unfinished Solid Queue RunJob refers to the queued Run;
  retry the Job to recreate it.
- **No live workers** means no fresh worker heartbeat is visible. Restore a
  worker before retrying.
- **Start blocked** uses the same admission-reason vocabulary shown elsewhere
  in the UI (for example, no capable worker or provider availability).
- **Unknown** is the safe fallback when Solid Queue state is unavailable or
  inconsistent. It deliberately does not claim that the worker pool is busy.

## Global agent-concurrency cap

`JOB_CONCURRENCY` caps agent Runs **per pod**, so total agent concurrency scales
with pod count. It defaults to the pod's own CPU budget -- 80% of its cgroup
CPU limit, rounded down, minimum 1 -- which is the same figure
`RunHostAdmission` rations against. Set it explicitly only to override that.
The production MySQL connection pool defaults to 9 connections per process,
enough for 6 run threads plus Solid Queue's 3-connection supervision headroom.
When setting `JOB_CONCURRENCY` above 6, also set `DB_POOL` to at least
`JOB_CONCURRENCY + 3`; `bin/check-thread-budget` enforces this relationship.
Give every worker pod a `resources.limits.cpu` (or set
`SYRUS_WORKER_CPU_LIMIT`): with no readable quota, `RunProcessParallelism`
deliberately assumes a small share rather than the node's core count, so an
unlimited pod runs *fewer* threads, not more. `AppSetting.max_concurrent_agent_runs` (admin-configurable,
`0` = unlimited) is a **cluster-wide** cap enforced by `RunJob`: if too many
agent (`:runs`-queue) Runs are already executing across all pods, a new one is
deferred and re-enqueued. Main-branch grader Runs are on `:runs` and are counted
too; landing/merge Runs are not counted. See `AppSetting` reference.

## Per-host Run pickup admission

Workflow admission control decides whether a workflow or phase should create a
Run before Solid Queue chooses a worker. A second, host-local guard runs inside
`RunJob` after the queued Run has been picked up but before the Run/Step/Workflow
are marked running. This closes the multi-worker gap where a generally valid
Run could still land on the one compute host already saturated by unrelated
CPU-heavy work.

The pickup guard applies to Runs whose workflow template uses the `:runs` or
`:merges` compute queues, including sticky `resume-<worker-storage-key>` retry
queues. It uses the current worker hostname (`SyrusVersion.hostname`), fresh
`worker_host_health_samples`, `workflows.worker_hostname` on already running
workflows, and command-attributed `workflow_step_resource_profiles` for the
narrow high-IO grader guard.

- If the selected host's latest fresh sample is critical, `RunJob` leaves the
  Run queued and re-enqueues it after `RunHostAdmission::RETRY_DELAY`, with one
  exception: criticality that comes **only** from IO pressure no longer defers a
  provider-bound agentic Run (every agentic Step except `visual_diff`). IO
  pressure is produced by the disk-bound work on the host -- graders installing
  dependencies, building assets and running suites -- while an agent turn spends
  nearly all of its wall time waiting on a provider API, so deferring it on that
  signal let grader fanout starve the work it was grading. Memory, disk space and
  CPU criticality still defer every compute Run, and `visual_diff` keeps its IO
  sensitivity because it drives a browser and a preview app of its own.
- Agentic Steps are resource-guarded on sight. Their host limit is derived from
  80% of the container's effective cgroup CPU quota, with each agentic Run
  consuming two capacity units. `SYRUS_AGENTIC_CAPACITY_UNITS` can tune that
  weight for a deployment.
- Every `grader` and `preflight_grader` Step consumes one host capacity unit.
  This matters for parallel fanout: sibling graders are independent Runs and
  cannot all pass admission against one stale idle sample. Each grader also
  receives `SYRUS_PROCESS_PARALLELISM`, its share of the same CPU budget, so a
  tool such as `parallel_rspec` cannot create an unbounded second fanout layer.
  `SYRUS_GRADER_CAPACITY_UNITS` can tune the default one-unit grader weight.
  Graders also leave one agent turn's worth of each host alone -- in capacity
  units and in the memory budget alike -- so a wide fanout cannot occupy a host
  so completely that the agent turns being graded have nowhere to start. The
  reserve defaults to `SYRUS_AGENTIC_CAPACITY_UNITS` and never costs a host
  its last grader: the capacity dimension floors the budget at the candidate's
  own units, and the memory dimension applies the reserve only once guarded
  work is actually running on the host, since with nothing running there is no
  agent turn to protect. Without that second rule a three-unit host reserved
  two units of memory -- 26 GB of a 31 GB budget -- and then refused a 13 GB
  grader on a completely idle host, deferring it every 30 seconds forever.
  `SYRUS_AGENTIC_RESERVED_UNITS` sets the reserve explicitly, including `0` to
  turn it off.
- A grader with command-attributed evidence of at least 1 GiB of IO also uses
  a narrower IO lane. Its automatic width scales slowly with host compute;
  `SYRUS_IO_INTENSIVE_RUNS_PER_HOST` can state the storage system's real
  concurrency when CPU count is a poor proxy. Host-correlated profile values
  never classify a grader as IO-intensive.
- Non-critical hosts with no existing guarded Run admit the pickup normally.
  Missing host telemetry is reported as `unknown`; it is not treated as either
  healthy or critical by this host-local guard.
- `visual_diff` Steps use the same narrower, host-scaled IO lane once the
  selected host is already at warning pressure or worse, regardless of how
  much general agentic headroom remains. A `visual_diff`
  Run drives a headless-browser preview on top of the agent turn itself, so
  colocating a second one on an already-loaded host is the kind of IO burst
  that produced critical pressure in past incidents. On a healthy host this
  guard does not apply and the plain agentic cap governs instead.

This is intentionally a pickup-time deferral, not a failure. The Run remains
`queued`; the Workflow and Step are not transitioned to `running`, no repair
iteration is spent, and the re-enqueued job preserves the current Solid Queue
queue and priority. On deferral, the Workflow artifact
`run_host_admission` records the action, reason, hostname, sampled health,
guard count/limit, resource guard kind, high-cost grader count when relevant,
step kind, Run id, queue name, whether the queue was sticky resume,
`deferred_at`, and `retry_at`. The Run also receives a system `JobLog` line:
`compute host admission deferred before <step_kind>: <reason>`.

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
- Claiming a generic capability-queue entry does not establish durable
  workspace affinity. A never-started Run can fail host admission and return
  to the fleet-eligible queue without recording either worker identity.
- After host admission and the execution lease succeed, immediately before a
  mutable Step handler can create or change the workspace, `RunJob` records
  both diagnostics hostname (`workflows.worker_hostname`) and routing key
  (`workflows.worker_storage_key`). Existing workspace owners retain that
  identity across later Steps, retries, process restarts, and worker crashes.
- On reopen / post-crash re-enqueue, `Run#enqueue_run_job` routes to
  `resume-<worker-storage-key>` only when a fresh Solid Queue worker advertises
  that queue and, for capability-specific work, advertises compatible
  capabilities. Immutable distributed grader Runs are intentionally non-sticky:
  they ignore the workflow storage key and route by their target capabilities.
  If no worker currently consumes a compatible resume queue — node gone,
  storage gone, old deployment without the queue, or incompatible host class —
  routing falls back to the normal capability queue and recovery relies on
  durable transcript rehydration or fresh retry.

This needs no deployment-specific node naming. With node-local `hostPath`, each
node gets a different storage key that survives pod replacement on that node.
With a shared RWX volume, all workers see the same id and safely share one
resume queue. With per-pod ephemeral storage, each pod gets its own id and
affinity lasts only as long as that storage does.

`worker_hostname` remains useful for diagnostics, process ownership, and worker
health correlation, but it is not the resume-routing key.

## How Workflow Admission Decides

Admission measures the host first and only uses step profiles where command
spans identify an individual costly grader.

- **`RunHostAdmission`** (per Run, on the compute queues) defers anything when
  the worker's own health sample reads critical — grader, agent or otherwise.
  Beyond that it derives a capacity budget from 80% of the container's
  effective cgroup CPU quota. Agentic Runs consume two units and grader Runs
  consume one. Command-attributed high-IO graders use an additional narrower
  IO lane. It leaves
  `STAGGER_INTERVAL` between agentic admissions on a host so each decision sees
  a sample that reflects the previous one. Grader fanout is not staggered; it
  uses the shared capacity and subprocess budgets. Pressure only defers new
  work; it never terminates an admitted process.
- **`WorkflowAdmissionBudget`** (per Workflow/phase) keeps the hard
  memory/disk gates, the urgent override, the landing-queue reservation, the
  minimum-progress floor, and one soft gate: `soft_host_pressure?`, which is a
  live reading of worker CPU, IO, memory and disk against `SOFT_HOST_PRESSURE`.

**Host-correlated profile predictions are not admission gates.**
`WorkflowStepResourceProfile` rows remain useful for spotting a step whose cost
regressed. The pickup guard only admits/defers on a profile when the candidate
is a grader/preflight-grader and the profile's prediction source is
`command_attributed`; ambient host-correlated pressure and conservative
defaults are diagnostics, not throttles.

## Workflow Admission Control Kill Switch

`AppSetting.workflow_admission_control_enabled` is the opt-in master switch for
soft capacity pacing. It defaults to `false`, so fresh single-host and Docker
Compose installs need no capacity tuning. Busy shared, multi-user instances can
enable it to apply `WorkflowAdmissionBudget` soft pressure and in-flight
limits, `RunHostAdmission` background yielding, host compute/memory reservations
and staggering, the global agent-run concurrency cap, and per-actor fair share.

Hard worker memory/disk exhaustion in `WorkflowAdmissionBudget` and critical
local pressure in `RunHostAdmission` remain unconditional. Provider circuits,
manual pauses, explicit landing pauses,
dependency blockers, landing-queue correctness gates, archived repositories,
missing PRs, and Job readiness checks also remain outside this switch.

Every disabled admission decision records `admission_control_disabled=true`,
the last changed timestamp/user, and the `bypassed_gates` list in the Workflow
admission artifact. Admin changes are audited as `AdminAction` rows
(`disable_workflow_admission_control` / `enable_workflow_admission_control`),
and toggling either direction wakes admission-delayed Workflows plus the
landing queue so existing sleepers are reconsidered promptly.

While admission control is enabled, Syrus also keeps a minimum-progress floor:
at least one admission-controlled workflow may start per healthy worker while
running agentic work is below that floor. This makes soft host pressure and
other workflow-level throttling signals a backstop rather than a total stop,
so landing and merge-train progress cannot starve behind uncertain conditions.
Hard worker memory/disk exhaustion and the non-admission blockers above still
win. Admission artifacts include the healthy worker count, active agentic run
count, floor capacity, whether the floor override was used, and the soft gates
that were present.

**Operator-facing visibility.** The full diagnostics view lives at
`/admin/resource_admission` (admin-only), backed by
`Admin::ResourceAdmissionDiagnosticsPayload`. For an admission-blocked Job,
the Job detail page also renders a pressure breakdown directly — which
dimension tripped (hard host pressure, soft ambient host pressure, or another
workflow-level admission gate), its current value versus the threshold that
tripped it, and the telemetry state behind the reading — via
`App::JobDetailPayload#job_json`'s `start_blocked_breakdown` field. Both
surfaces format the same recorded `WorkflowAdmissionBudget::Decision#artifact`
through the shared `AdmissionDiagnostics::Breakdown` service (never
re-running the admission decision) so the numbers can't drift between them.
`telemetry_state` of `"stale"` or `"absent"` renders as a distinct callout
("no telemetry recorded — treating conservatively") so operators can tell a
monitoring gap from a genuinely busy host. Admin users additionally get a
"View pressure diagnostics" link (via `StartBlockedReasonPill`'s optional
`diagnosticsPath` prop) out to the full admin page; the Job payload only
includes the link's path when `Job::actions.can_view_resource_admission_diagnostics`
is true (i.e. the requesting user is an admin).

`AppSetting.host_admission_policy` chooses *how a worker decides it has room*,
independently of the workflow-level policy below.

- `prediction` (default) forecasts each step's cost from
  `WorkflowStepResourceProfile`, sums the forecasts for the runs already on the
  host, and refuses when the total exceeds the memory budget. It is accurate
  only where a profile exists. A profile must match repository, agent provider,
  trigger kind, job kind and step kind (plus grader name) *and* have at least
  ten attributed samples; anything else falls back to a flat
  `host_memory_limit / host_compute_capacity` per compute unit -- a sixth of
  the host for a grader, a third for an agentic step. Three such estimates
  exhaust a budget regardless of what the machine is doing, which is how a
  host can refuse work while measuring a fraction of its limit in real use.
- `usage` reads what the host is actually doing. Memory PSI
  (`memory.pressure`, `some avg10`) reports the share of time at least one
  task stalled waiting on memory, which is the condition that actually
  matters: a cgroup can sit near its limit indefinitely while reclaiming
  without a single stall, and such a host is fine. Admission refuses only
  above `SYRUS_MEMORY_PRESSURE_CEILING` (default 10%). Compute units still
  bound concurrency, because PSI lags -- without a width limit a burst
  admitted inside one window all starts before pressure registers. When
  `memory.pressure` cannot be read the policy admits rather than refusing
  blindly.

Every admission decision records `admission_policy`, and under `usage` also
`memory_pressure_some` and `memory_pressure_ceiling`, so an admit is as
auditable as a refusal. `resource_guard_binding_terms` names
`memory_pressure` instead of `memory_reservation`/`measured_memory` under the
usage policy.

Switching is instance-wide and takes effect on the next decision; no restart
is needed. `prediction` remains the default so the setting appearing changes
nothing until an operator opts in.

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
scheduled admission wakeup remains the fallback for resuming them when pressure
clears. Syrus also enqueues a bounded capacity wakeup whenever a Run or Workflow
finishes while admission/resource sleepers exist, so blocked work is
reconsidered promptly when active work frees capacity instead of waiting for the
full backoff. `WorkflowPhaseAdmissionJob` retries the next queued step after
either wakeup path.

The per-host Run pickup admission described above is separate from
`WorkflowAdmissionBudget`: it runs after Solid Queue selects a concrete worker
and can therefore act on that worker's local pressure and already-running
guarded Runs. It records `run_host_admission` artifacts instead of
`start_blocked_details` / `pause_details`, because it does not change workflow
phase ownership or create a WorkUnit admission block.
