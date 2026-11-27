# Multi-worker operations

## External plugins

Set `SYRUS_PLUGIN_PATH` to the single shared directory containing externally
installed plugin directories. Mount the same contents read-only in every web,
worker, preview, setup, and other process that boots Rails. Plugin names must
be unique across that directory and the built-in plugin root; a built-in
plugin wins a collision and the external copy is skipped. For Kubernetes/k3s,
this variable is the deployment contract; provisioning and installation of a
shared plugin volume are intentionally deployment-specific.

## Spreading workers across nodes (queue partitioning)

The search index is SQLite FTS5 on a single-node RWO volume, so the queues that
touch it can't spread. To run agent compute on multiple nodes anyway, split the
queues across two worker configs and select one per pod with the
`SOLID_QUEUE_CONFIG` env var:

| Config | Queues | Where |
| --- | --- | --- |
| `config/queue.home.yml` | `chat`, `videos`, `control_plane`, `operator_actions`, `polling`, `indexing`, `cleanup`, `low_priority_maintenance` (+ its `resume-<worker-storage-key>`) | one pod, on the node holding the search PVC / with the web pods |
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

## Native macOS compute workers

Native Mac hosts are external, launchd-managed **compute-only** workers for
Xcode, SwiftPM, and iOS simulator work. They are not Kubernetes nodes. A
Linux VM on Mac hardware may join k3s as Linux capacity, but it cannot stand
in for native Xcode. Everything about them (install, env file, updates,
troubleshooting) lives behind the [macOS workers hub](macos-workers.md).

How the tiers split across queues in a hybrid layout:

| Tier | Location | Queue/role boundary |
| --- | --- | --- |
| Web | k3s | HTTP app, API, admin UI, metrics |
| Home worker | one k3s pod | `chat`, `polling`, `indexing`, `cleanup`, `control_plane`, `operator_actions`, `videos`, home resume queue |
| Linux compute | k3s pods | `runs`, `runs-linux-amd64`, `merges`, `merges-linux-amd64`, local resume queue |
| Mac mini pool | external launchd | `runs-macos-arm64`, `merges-macos-arm64`, compatible `resume-<worker-storage-key>` queues |
| Data services | k3s or managed | MySQL, storage, release artifacts, search/data volumes |

## Home worker and chat affinity

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
HEAD to an immutable handoff branch after confirmation, and attached-Job
`complete_implement_step` captures the current checkout HEAD to the appropriate
handoff branch after confirmation before handing work to the `coding_handoff`
workflow. Once the workflow starts, it owns any further repair and publication
work from a normal workflow checkout, so it runs safely on any compute pod.

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

### Docker Compose CPU sizing

Docker Desktop, OrbStack, and Colima may expose no cgroup CPU quota inside the
worker container. For installs managed by `install.sh`, the installer records
the Docker VM's CPU count as `SYRUS_WORKER_CPU_LIMIT` in `.env` the first time
the key is missing or blank. Because `docker-compose.yml` supplies that file to
the shared app configuration, the worker receives it without extra wiring.

If worker capacity is unexpectedly low or Runs remain blocked with
`host_resource_semaphore_busy`, check that `SYRUS_WORKER_CPU_LIMIT` is a
positive integer appropriate for the VM, then restart the worker. The installer
never replaces a nonblank operator value when the VM size changes. Manual
Compose setups can add the same key to `.env` themselves.

Manual Job pause is operator-controlled and is not an admission-control signal.
It persists on the Job (`manual_paused`) and takes effect at the next Step
boundary: the current Run finishes, then the dispatcher records
`pause_reason: manual_pause` on the Workflow and does not enqueue another Run.
Manual pauses have no automatic `next_check_at`; only an operator unpause clears
the flag and lets normal admission/dependency/provider checks decide when the
workflow can proceed.
