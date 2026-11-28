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
`runs`, `runs-linux-amd64`, `merges`, `merges-linux-amd64`, and
`runtime_image_builds` (the runtime image build pool); a macOS worker
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

## Worker environment smoke checks

Capabilities say what a worker is; the environment smoke checks prove its
toolchain actually works for the work Syrus routes to it. Every worker runs
them when it starts (including after a macOS worker self-update) and again
about every 15 minutes, and publishes the result with its capabilities. Checks
run the way a prepare command runs, with the same forwarded environment, and
finish in a few seconds. They are side-effect free: compiles happen in a
private temporary directory, and the data-root check removes its own scratch
files.

| Check | What it proves |
| --- | --- |
| `workflow_data_root` | `SYRUS_DATA_ROOT` exists and is writable; `flock`, hardlinks and rename work in `workflows/.locks`; at least 5 GiB is free (`SYRUS_WORKER_SMOKE_MIN_FREE_BYTES` overrides) |
| `tmp` | the temporary directory is writable |
| `git`, `ruby`, `bundler`, `node`, `npm`, `gh` | the CLI is on `PATH` and `--version` succeeds |
| `c_compiler` | the `ruby` on `PATH` can compile and link a trivial C program through `mkmf`, as every native gem's build does |
| `mysql_client` | mysql2 would find a MySQL client (its build flag, `mysql_config` on `PATH`, or mysql2's default locations), and `mysql.h` compiles, the client library links, and a program linked against it starts |
| `browser` | `playwright-mcp --version` succeeds (declared by the Browser plugin's visual review steps) |
| `agent_cli_<provider>` | the agent provider's CLI starts, e.g. `claude --version`, `codex --version` |

A failed check fails closed for the work that needs it, and only that work:

- every step needs `workflow_data_root`, `tmp`, and `git`;
- an agentic step needs its agent provider's CLI, and `gh` when the workflow
  was granted break-glass GitHub access;
- visual review and visual diff steps need `browser`;
- a repository's steps need what its prepare plan was last seen to use:
  `bundle install` needs `ruby`, `bundler`, and `c_compiler`; npm, yarn and
  pnpm commands need `node` (and `npm`); a `Gemfile.lock` that contains mysql2
  adds `mysql_client`. Syrus records this when a workspace for the repository
  is prepared, so the repository's first workflow routes on the base checks
  only.

A worker that failed a check a step needs is not chosen for that step, and if
it already holds the Run it hands the Run back to the queue instead of starting
it. When no live worker that could run the step passes, the Workflow waits with
`no_capable_worker` and the reason `worker_environment_check_failed`; the
admission details list each worker's failed checks with their reasons. Nothing
fails, and the step starts once a worker's next report passes. A worker that
has not published a report, or does not report a check, is treated as unknown
rather than failed. An explicit `.syrus.yml` prepare plan that reaches a
worker that already failed one of its checks stops immediately with the failed
check named, instead of failing later in `bundle install`.

Worker health shows each failed check with its reason: a warning when it only
keeps the worker off the work that needs it, critical when every Run needs it.
`gh` is advisory: the Linux worker image leaves it out on purpose, so its
failure gates break-glass GitHub access without raising worker health. The
admin version endpoint reports each worker's `environment_smoke` status and
failed checks.

To run the checks on demand on a worker host:

- `bin/rails syrus:worker_environment_smoke` runs every check, including the
  ones plugins contribute (`JSON=1` prints the full report);
- `bin/worker-environment-smoke` runs the core checks without booting Rails;
  `bin/macos-worker-check` includes it, failing on a check every Run needs and
  warning on the others.

Set `SYRUS_WORKER_ENVIRONMENT_SMOKE=0` on a worker to stop it publishing a
report, which makes every check read as unknown again.

## Global agent-concurrency cap

`JOB_CONCURRENCY` caps agent Runs **per pod**, so total agent concurrency scales
with pod count. It defaults to the pod's own CPU budget -- 80% of its cgroup
CPU limit, rounded down, minimum 1 -- which is the same figure
`RunHostAdmission` rations against. Set it explicitly only to override that.
The production MySQL connection pool defaults to 9 connections per process,
enough for 6 run threads plus Solid Queue's 3-connection supervision headroom.
When setting `JOB_CONCURRENCY` above 6, also set `DB_POOL` to at least
`JOB_CONCURRENCY + 3`; `bin/check-thread-budget` enforces this relationship.
Give every worker pod a `resources.limits.cpu`, set `SYRUS_WORKER_CPU_LIMIT`,
or point `SYRUS_WORKER_CPU_BUDGET_FILE` at a file holding the core budget (for
example, written at pod start from what the node has left after every other
pod's CPU requests, so one manifest sizes nodes of different sizes): with none
of these, `RunProcessParallelism` deliberately assumes a small share rather
than the node's core count, so an unlimited pod runs *fewer* threads, not
more. `AppSetting.max_concurrent_agent_runs` (admin-configurable,
`0` = unlimited) is a **cluster-wide** cap enforced by `RunJob`: if too many
agent (`:runs`-queue) Runs are already executing across all pods, a new one is
deferred and re-enqueued. Main-branch grader Runs are on `:runs` and are counted
too; landing/merge Runs are not counted. See `AppSetting` reference.

## Per-host Run pickup admission

Workflow admission control decides whether a workflow or phase should create a
Run before Solid Queue chooses a worker. A second, host-local check runs inside
`RunJob` after the queued Run has been picked up but before the Run/Step/Workflow
are marked running. It applies to Runs on the `:runs` and `:merges` compute
queues, including sticky `resume-<worker-storage-key>` retry queues.

The check is measured, not predicted: a worker takes more work while it is
demonstrably healthy and backs off when it demonstrably is not. There are no
per-step cost estimates, capacity units or reserves.

- **Critical host.** If the worker's latest fresh health sample is critical,
  the Run is deferred -- except that criticality coming only from IO pressure
  does not defer a provider-bound agent turn (every agentic Step except
  `visual_diff`), which spends nearly all of its time waiting on a provider API.
- **Memory pressure.** Live memory PSI (`some`, avg10) at or above
  `SYRUS_MEMORY_PRESSURE_CEILING` (default 10%) defers every guarded Run.
- **Memory headroom.** The pod's memory limit minus its working set -- which
  excludes clean page cache and reclaimable slab -- below 2 GB defers every
  guarded Run.
- **Compute concurrency.** Compute Runs (everything except provider-bound agent
  turns) are bounded by a per-worker concurrency target. It starts at the
  worker's CPU count, grows by one every 30 seconds while the worker is full
  and its CPU is below 90% used, holds while CPU is at or above that, and
  halves only on memory trouble: memory pressure at half its ceiling or the
  memory health dimension at warning. Busy CPU and IO never shrink it, and a
  halved target returns to the CPU count after 5 minutes without memory
  pressure, whether or not the worker is busy.
  The target lives on the worker and restarts from the CPU count.
- Graders still receive `SYRUS_PROCESS_PARALLELISM`, their share of the CPU
  from the resource grant, so a tool such as `parallel_rspec` sizes itself
  rather than taking every core.
- A `running` Run counts against a worker only with credible current ownership
  there: an unfinished `SpawnedProcess` on the host, or -- for Runs whose
  workflow is placed on the host -- a fresh heartbeat (or a start within 10
  minutes, before the first heartbeat) or a recently touched active
  `RuntimeSession`. A Run whose worker or process vanished stops counting at
  once. Admission details list the counted Runs as `active_run_ids` and
  `active_run_liveness_evidence`.

Overload is bounded by the halving and by the cgroup limits on spawned
processes, and made cheap rather than prevented: a Run a worker loses to memory
pressure is retried as an infrastructure failure, not charged to the Job.

This is a pickup-time deferral, not a failure. The Run remains `queued`, no
repair iteration is spent, and the re-enqueued job keeps its queue and
priority; a distributed grader is rerouted to the least-loaded healthy worker.
On deferral the Workflow artifact `run_host_admission` records the reason, the
binding term (`memory_pressure`, `memory_headroom` or `concurrency_target`),
the worker's concurrency target and compute Run count, its memory headroom and
pressure, and the counted Runs. The Run also receives a system `JobLog` line:
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

Every host admission decision records `memory_pressure_some` and
`memory_pressure_ceiling`, so an admit is as auditable as a refusal.

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
