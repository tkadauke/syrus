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
| `config/queue.home.yml` | `chat`, `default`, `videos` (+ its `resume-<host>`) | one pod, on the node holding the search PVC / with the web pods |
| `config/queue.compute.yml` | `runs`, `merges` (+ its `resume-<host>`) | one pod per worker node; local disk, no search mount |

- **The home worker** runs everything bound to the single-node search index or
  co-located with it: `default` (Index\*Job = search **writes**, pollers,
  reapers, broadcasts), `chat` (search **reads** via the `search_chats` MCP
  tool), and `videos`. It consumes `default`, so it is the tier that
  **schedules recurring tasks** — leave `SOLID_QUEUE_SKIP_RECURRING` unset here.
- **The compute worker** runs the heavy, search-free queues — `runs`
  (implementation, response, grader, and `main_grader` RunJobs) and `merges`
  (landing / rebase) — which enqueue their search updates onto `default` rather
  than touching the index directly. Spread it one-per-node on fast local disk.
  Set `SOLID_QUEUE_SKIP_RECURRING=1` so only the home worker schedules recurring
  jobs.
- Both configs consume this pod's own `resume-<hostname>` queue, so
  retry-from-failed-step affinity (below) works on whichever pod holds the
  workspace.

**The home worker MUST be a single pod** (`replicas: 1`, `strategy: Recreate`).
Chat workspaces (`ChatWorkspace`, at
`$SYRUS_DATA_ROOT/chat-workspaces/<chat_session_id>`) are local-disk and
long-lived, and — unlike Workflows — chat has **no** pod-affinity mechanism:
`chat_sessions` records no `worker_hostname`, and `ensure_coding_checkout!`
is a no-op once the coding branch exists (`return if
coding_checkout_branch.present?`), so it never re-clones on a second pod. A chat
session's turns therefore MUST all land on the same pod, which holds only because
exactly one pod consumes `chat`. Never put `chat` on the compute DaemonSet, and
never scale the home worker past one replica. (If the chat tier ever needs to
scale, chat first needs its own per-pod affinity — a `resume-<hostname>`-style
chat queue keyed off `chat_sessions.workspace_path`.) Coding-mode **handoff** is
exempt: `complete_implement_step` / `submit_coding_changes` require the branch to
be pushed to the remote first, so the resulting `coding_handoff` Workflow clones
fresh from GitHub and runs safely on any compute pod.

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

## Retry-from-failed-step worker affinity

Each Job keeps at most one on-disk workspace (see the workspace-per-Job change).
On local-disk-per-worker deployments that workspace lives on **one** pod, so a
"Retry from failed step" (`Workflow#reopen`) must resume on that pod.

- When a `RunJob` runs a workflow it records the pod in `workflows.worker_hostname`
  (`SyrusVersion.hostname` — the same value `InstanceVersion` heartbeats).
- Each worker consumes its own per-pod queue `resume-<hostname>` (declared in
  `config/queue.yml`, alongside `runs`).
- On reopen / post-crash re-enqueue, `Run#enqueue_run_job` routes to
  `resume-<hostname>` **only when that pod is still alive**
  (`InstanceVersion.worker_live?`, 2-minute heartbeat window). If the pod is
  gone — deploy, eviction, restart with a new pod name — its local workspace is
  gone too, so routing falls back to the normal `runs` queue and any worker
  re-clones a fresh workspace (a normal "start over").

This needs no configuration: on a single worker it routes reopens back to that
worker; in local/dev (no `InstanceVersion` rows) it degrades to the normal
queue. It becomes load-bearing once you run multiple workers on local disk.

Note: affinity is keyed on the **pod hostname**. A pod restarting on the same
node with a `hostPath` workspace volume gets a new hostname, so a pending reopen
degrades to a fresh clone even though the files are still on the node — correct,
just not optimal. Keying on node name would tighten that later.

## Per-worker workspace pruning

A workspace lives on the local disk of the pod that ran the workflow, so one pod
can't clean another's. Two safeguards make pruning worker-local:

- `WorkflowWorkspace.cleanup_for` skips a workflow only when a **live** worker
  pod (`InstanceVersion.worker_live?`) still owns it, so a prune pass can't
  false-stamp `cleaned_up_at` on a workspace that's still on another pod. It
  cleans normally when the recorded host is this pod, is blank (legacy /
  single-worker), or is no longer a live worker — the last case covers
  single-host Docker, where a backend update recreates the worker container with
  a new hostname but the shared volume (and its leftover workspaces) persist.
- `WorkflowWorkspacePruneJob` (recurring) is a coordinator: it runs the
  cluster-wide DB/branch and chat sweeps once, then **fans the local filesystem
  sweep out to every live worker** via each pod's `resume-<hostname>` queue. With
  no tracked workers (single-host / dev) it sweeps the local disk directly.

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

The current admin overview, `/api/v1/admin/version`, and the admin queue
workers payload include worker health snapshots alongside the existing
data-root disk fields. Disk alerts still come from the most-full worker's
`InstanceVersion` reading so existing alert behavior is unchanged. For deeper
inspection, `/api/v1/admin/worker_health` and `/api/v1/app/admin/worker_health`
return live worker status plus compact 15m/1h/6h/24h summaries, recent
samples, and bounded minute-resolution buckets. By default each host includes
one bucket per minute for the last hour, ending at `until`; callers can increase
that bounded minute window with `minute_bucket_window_minutes` up to 24 hours.
Each bucket includes the minute timestamp, sample count, warning/critical
counts, and max/avg summaries for CPU, load, memory, data-root disk, CPU
pressure, and IO pressure. The payload can be filtered with `hostname`, `since`,
`until`, `sample_limit_per_host`, and `minute_bucket_window_minutes`.

Admin chat agents can call `read_worker_health` for the same payload. Use it
when diagnosing pod-local pressure, recurring worker warnings, or failure
patterns that may correlate with CPU, memory, disk, or IO pressure.
