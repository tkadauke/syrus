# Background jobs and queues

Use these rules when adding or changing asynchronous execution, queue placement, scheduling, and process supervision.

- **Per-Job concurrency** — `RunJob` uses Solid Queue's `limits_concurrency`
  keyed on `job_id` so two Workflows on the same Job never overlap. (Was
  per-repo; changed because the shared WorkflowWorkspace path is per-Workflow-id,
  so the collision risk is within a Job, not across repos.)
- **Consumed queue resolution** — every job class must resolve to a queue that
  a deployed worker consumes. Prefer an explicit `queue_as` when the class has
  its own workload policy; deliberate inheritance from `ApplicationJob` is
  valid when the application default is the intended policy. Review either
  choice when changing the class. Queue names, consumers, and worker topology
  are operational inventory: read `config/queue.yml`,
  `config/queue.compute.yml`, `ApplicationJob`, and
  `spec/config/queue_partitioning_spec.rb` instead of copying their current
  membership or thread counts into durable guidance. Framework jobs that
  subclass `ActiveJob::Base` directly must be routed in
  `config/application.rb` because they do not inherit the application queue.
- **Recurring work is registry-owned** — add recurring entries through
  `config/recurring.yml` and the recurring-work loader, with an allowed
  isolated queue. Treat the entries and their cadences as executable inventory,
  not durable prose; do not copy the current list here.
- **Substantial repairs use maintenance definitions** — durable backfills and
  repair tasks belong in `MaintenanceTasks::Registry` with a stable definition,
  checkpoints, bounded batches, concurrency identity, and explicit completion
  behavior. Registry membership is executable inventory. See the database
  convention for the plugin boundary and small-migration exception.
- **Per-user scheduling pause** — `User#scheduling_paused` (boolean).
  `PollScheduledTasksJob` skips paused users entirely. Operator can toggle
  via admin UI; user can toggle in `/credentials/edit`.
- **Per-Job priority** — `Job#priority` is `high` / `medium` (default) /
  `low`. Converted to SolidQueue integers at enqueue time via
  `Job#solid_queue_priority` (high→0, medium→10, low→20); the
  `Run#enqueue_run_job` path and paused-run re-enqueue in `RunJob` both
  use it. Admin API exposes `priority` on job list and detail responses.
- **Per-instance version tracking (`InstanceVersion`)** — Every
  web pod and worker pod registers a row in `instance_versions` on
  boot via `InstanceVersionSupervisor` (started from a
  `to_prepare` initializer when `ENV["SYRUS_ROLE"]` is set —
  manifest-driven, skipped in local/test/console). The row carries
  hostname, role, git SHA (from `ENV["GIT_SHA"]` baked into the
  image by `bin/deploy`), started_at, and a heartbeat thread bumps
  `last_heartbeat_at` every 30s. `at_exit` stamps `finished_at`
  on graceful SIGTERM; `ReapStaleInstanceVersionsJob` (every
  minute) finalizes rows whose heartbeat hasn't moved for 5+ min
  (SIGKILL / OOMKill / node eviction). `GET /api/v1/admin/version`
  returns the request handler's identity plus every fresh
  instance — useful for confirming a deploy has finished rolling
  (during a deploy you see both old + new SHAs in the
  `instances` array until the old pods drain).
- **Subprocess inventory (`SpawnedProcess`)** — every subprocess spawned
  through `ProcessRunner` (agent CLIs, graders, git, prepare) registers a
  row, heartbeats on every output chunk, and finalizes on exit. `kind`
  is a strict CONSTANT enum (`SpawnedProcess::KINDS`) — new spawn sites
  must register a kind. The operator-facing list lives at `/admin/processes`
  with kind/hostname/run filters + per-row Kill button. Kill stamps
  `kill_requested_at`; the owning worker's `ProcessRunner` polls the row
  once per second and terminates the local pid. `SpawnedProcess#host_metrics`
  reads `/proc/<pid>/{status,stat}` on Linux for live CPU/RSS readout.
  Two-layer cleanup catches orphans without timeout-based guessing:
  `SpawnedProcessSupervisor` is an in-process ticker thread that
  ProcessRunner.new lazy-starts on first call; every 30s it walks
  own-hostname rows and finalizes any whose pid is gone (detects
  Ruby-thread death / OOM-killed subprocesses inside an otherwise-
  alive pod). `ReapOrphanedSpawnedProcessesJob` (every minute) handles
  the cross-hostname case — finalizes rows whose hostname isn't in
  the current `SolidQueue::Process.distinct.pluck(:hostname)` set
  (detects dead pods within ~5 min of SQ pruning the worker). Both
  paths use conditional `update_all(WHERE finished_at IS NULL)` so
  they race safely with each other and with ProcessRunner's own
  finalize call. `SpawnedProcessPruneJob` (daily 3:20am) deletes
  finished rows past 7 days. `SpawnedProcess` optionally belongs to a
  `chat_session` alongside its existing `run`/`workflow` associations —
  `ChatTurnJob` sets `Thread.current[:syrus_current_chat_session]` around
  the agent invocation (mirroring `RunJob`'s `:syrus_current_run`) so
  `ClaudeInvocation`/`CodexInvocation` can attribute chat-turn `agent`
  processes to their chat, and `ChatWorkspacePrepareJob` attributes
  `chat_prepare` processes the same way. `Admin::SpawnedProcesses::Payload`
  derives a best-effort `owner` summary (`type`/`label`/`path`) from
  `workflow` (→ Job), `chat_session`, or — for `preview` processes, which
  are spawned directly by `PreviewService` rather than through
  `ProcessRunner` — the `job_id` already carried in `resource_attribution`.
  Coverage isn't exhaustive (e.g. `credential_probe`/`chat_stt` processes
  still resolve to no owner); the admin Processes list and detail page
  render `owner` as a link when present.
