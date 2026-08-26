# Production performance and load plan

Captured July 14, 2026 from a production incident where the app felt slow
while JOB-1711 and JOB-1713 were running.

Status check 2026-08-26: this is still relevant as historical load-analysis
rationale, but many observability gaps named here have since been addressed.
Syrus now has request/job/browser/SQL performance traces, operational logs,
browser/backend exception logs, MySQL live inspection, worker health snapshots,
and admin performance views. Treat the July incident evidence as a baseline
for why those systems exist, not as a current statement that production
performance logging is unavailable.

## Goal

Make Syrus responsive under real agent load. The target outcome is that
operators can answer these questions quickly:

- Is the slowness web, database, queue, worker CPU, disk, provider, or
  network related?
- Which Jobs/Runs are consuming the most resources right now?
- Are background pollers/reapers doing useful work or churning?
- Can we spread heavy worker load across the cluster without breaking
  workspace, terminal, or provider-session assumptions?

## Current Evidence

Observed during the incident:

- `k3s-production-master-03` was at 100% CPU.
- Both `syrus-web` pods and the single `syrus-worker` pod were scheduled on
  that same node.
- `syrus-worker` used roughly 3.5 cores and 6.3 GiB RAM.
- MySQL was not the immediate hot spot: roughly 0.1 core CPU and 2.9 GiB RAM,
  with no recent redo-log or lock-wait storm in the MySQL logs.
- The worker data volume was high but not full: `/syrus-home` around 85%.
- Pending Solid Queue jobs were empty at the sampled moment; the `runs` pool
  had two active Runs.
- JOB-1711 was not idle. Its workflow had already spent about:
  - 5 minutes in `prepare`
  - 40 minutes in the first `implement` run
  - 6 minutes in `adversarial_review`
  - then entered a second `implement` run that launched full `bin/rspec`
- The active JOB-1711 process tree included a long-running `bin/rspec` child
  plus Claude task-output tails.
- JOB-1713 was compiling C++ coverage with multiple `cc1plus` processes.
- Web logs showed Action Cable upgrade failures:
  `Request origin not allowed`, followed by repeated REST polling of run
  artifacts.
- Job detail requests for JOB-1711 were modest individually but non-trivial:
  about 124 SQL queries per full job payload request.
- `PollRepositoryJob` for `tkadauke/syrus` took about 31 seconds in a recent
  sample and emitted high-volume dedup/ingestion logging.
- `ReapStaleRunsJob` repeatedly attempted workflows blocked by
  `main_branch_broken`, causing recurring background churn.
- Performance logging reported `enabled=false`, so no in-app slow request/SQL
  event buffer was available for this window.

## Diagnosis

This is multifactorial. Treating it as "just slow SQL" will miss the larger
failure mode.

### 1. Worker CPU can starve web

The web pods were lightweight, but they shared a fully saturated node with a
compiler-heavy worker. Even efficient web requests can feel slow when the node
has no CPU headroom.

### 2. Agent workflows can become very expensive

Main-branch repair and normal implementation workflows can spend many turns
and then run full test suites inside the `implement` step. That is sometimes
useful, but it makes one Job capable of consuming a large fraction of the
cluster's worker capacity.

### 3. Live update fallback amplifies request load

When Action Cable is blocked by origin checks, the UI falls back to repeated
HTTP polling. That makes job detail pages reload enough data to become a
meaningful cost during already-high load.

### 4. Pollers and reapers can churn

External polling is the core architecture, but full or noisy repository polls
and repeated "blocked, try again later" dispatcher loops can burn time without
moving work forward.

### 5. Current observability is too shallow

The app has performance logging infrastructure, but production logging was off
during the incident. We need always-available high-level load visibility and
opt-in detailed traces for slow requests, SQL, phases, and queue work.

## Can We Add More Worker Pods?

Yes, in theory. Solid Queue can distribute jobs across multiple worker
processes and pods as long as they share the same queue database.

However, scaling the current `syrus-worker` Deployment is not automatically
the right first move.

### What works already

- Solid Queue workers can be replicated.
- Per-Job concurrency guards prevent two Workflows on the same Job from
  overlapping.
- Terminal relay routing stores the worker relay address, so multiple worker
  pod IPs are conceptually supported.
- Kubernetes can spread replicas across hosts if we add pod anti-affinity or
  topology spread constraints.

### What must be checked before scaling

- `$SYRUS_DATA_ROOT` contains workflow workspaces and provider/session homes.
  A later Step in the same Workflow may be claimed by a different worker pod.
  That pod must be able to see the same workspace and provider session files.
- If the current Longhorn volume is ReadWriteOnce, multiple worker replicas may
  either fail to mount or be forced onto the same node. That would not solve
  host-level contention.
- If we move to per-pod volumes, we need workflow-to-pod affinity or workspace
  transfer. That is more complex and risks breaking resume, grade logs, and
  terminal/session behavior.
- Scaling the current all-in-one worker pod multiplies every queue pool:
  `runs`, `merges`, `chat`, `videos`, and `default`. That can accidentally
  multiply polling, merge, and chat capacity when the real need is only more
  CPU isolation for `runs`.
- Database connection pool and MySQL connection limits must scale with the
  total number of worker processes and threads.

### Recommended scaling path

Do not start by simply increasing `replicas` on the existing all-queue worker.

First split workers by queue role:

- `syrus-worker-default`: pollers, reapers, broadcasts, maintenance
- `syrus-worker-chat`: chat turns and chat workspace maintenance
- `syrus-worker-merges`: auto-merge, rebase, merge train
- `syrus-worker-runs`: agent implementation/repair/grader-heavy work
- optionally `syrus-worker-videos`: video walkthrough analysis

Then add scheduling rules:

- keep `syrus-web` away from `syrus-worker-runs`
- keep `syrus-worker-default` small and responsive
- allow `syrus-worker-runs` to use CPU-heavy nodes
- add topology spread constraints for run workers

After that, scale `syrus-worker-runs` horizontally only if storage is safe:

- preferred: shared ReadWriteMany storage for `$SYRUS_DATA_ROOT`
- acceptable but more complex: per-pod workspaces plus explicit workflow
  affinity and artifact/session persistence outside the filesystem

## Work Plan

### M1 - Stop web from sharing saturated CPU

Deliverables:

- Add Kubernetes anti-affinity so `syrus-web` does not co-locate with
  `syrus-worker-runs`.
- Add resource requests/limits for web and worker pods.
- Add node/pod visibility to the admin API: pod name, node name, CPU, memory,
  queue profile.
- Add an operator-facing "current load" panel showing active Runs, queue depth,
  worker pod placement, and node saturation.

Success criteria:

- Web pods retain CPU headroom while a C++ or full Rails test run is active.
- Operators can see which pod and node owns a slow Run.

### M2 - Split worker deployments by queue role

Deliverables:

- Introduce a queue profile configuration so a pod can run only one queue
  group instead of every pool in `config/queue.yml`.
- Deploy separate worker profiles for `default`, `chat`, `merges`, `runs`, and
  `videos`.
- Keep `default` and `chat` low-latency even when `runs` is saturated.
- Update readiness/admin UI to show queue profile per worker process.

Success criteria:

- A long `runs` queue Run cannot delay reapers, pollers, app-event broadcasts,
  or chat wakeups.
- Increasing run capacity does not accidentally multiply every other queue.

### M3 - Make worker horizontal scaling safe

Deliverables:

- Confirm the current `$SYRUS_DATA_ROOT` volume access mode in production.
- Decide between:
  - ReadWriteMany shared worker storage, or
  - per-pod workspaces with explicit workflow affinity and durable artifacts.
- Verify Claude/Codex resume files, MCP sidecar logs, grade logs, terminal
  sessions, and workflow workspaces survive the chosen topology.
- Add deployment constraints that spread `syrus-worker-runs` pods across hosts.

Success criteria:

- Two run worker pods on different nodes can execute sequential Steps of the
  same Workflow without losing workspace or provider-session state.
- A terminal session advertises the correct pod IP and remains reachable.

### M4 - Fix Action Cable before optimizing polling

Deliverables:

- Fix production allowed origins for Action Cable.
- Add a warning metric/log when WebSocket upgrades fail by origin.
- Reduce job-detail polling frequency once live updates are healthy.
- Split job detail payloads so run artifact tails do not require reloading the
  entire job/workflow graph.

Success criteria:

- Job pages update live without repeated full REST reloads.
- A single visible job page does not produce continuous high-query traffic.

### M5 - Reduce expensive workflow behavior

Deliverables:

- Add step-specific budgets for special workflows:
  - main repair implement
  - adversarial review
  - summarize/test-plan
  - grader/coverage lanes
- Make main-branch repair prompts include the exact failing health check output
  before the agent starts.
- For main repair, consider skipping adversarial review by default and relying
  on required graders.
- Detect long-running background commands from agent tools and surface them in
  the run UI.
- Add a per-run "current command" heartbeat so operators know whether a Run is
  actively testing, compiling, waiting on provider output, or stuck.

Success criteria:

- Main repair Jobs do not spend an hour rediscovering known failures.
- Long commands are visible and bounded.

### M6 - Reduce poller/reaper churn

Deliverables:

- Make `PollRepositoryJob` incremental where possible:
  - poll updated issues first
  - perform bounded recent-page scans
  - run occasional full reconciliation separately
- Replace per-issue dedup logs with aggregated counts.
- Fix cursor/order warnings in poll jobs.
- Stop re-dispatching workflows blocked by `main_branch_broken` every minute;
  record a blocked reason and backoff/next-check timestamp instead.

Success criteria:

- Normal repository polls complete quickly and produce compact logs.
- Blocked workflows do not generate recurring no-op dispatcher work.

### M7 - Make performance logging useful

Deliverables:

- Keep lightweight performance counters always available.
- Keep detailed request/SQL/phase logging behind the existing feature gate.
- Persist detailed events somewhere queryable through the admin API; do not
  rely only on a tiny Rails cache window.
- Record:
  - request path/action/status/duration
  - DB time and query count
  - GC time and allocations if available
  - slow SQL fingerprint
  - queue wait time and job duration
  - worker pod, node, queue profile
  - active Run id/Job id when present
- Add admin API endpoints for:
  - recent slow requests
  - slow SQL fingerprints
  - queue latency by queue
  - longest active Runs
  - repeated churn events

Success criteria:

- During the next incident, the admin API can explain where time is going
  without requiring ad hoc `kubectl logs` archaeology.

## Operating Guidelines

- Do not tune SQL before checking node CPU, worker command mix, queue depth,
  and Cable health.
- Do not scale all worker queues together unless the incident proves every
  queue needs more capacity.
- Do not let run workers share a node with every web pod.
- Treat full-suite tests and C++ coverage as cluster-level load, not just
  "agent internals."
- Keep a visible distinction between:
  - queued waiting for capacity
  - running but blocked on a long command
  - running and waiting for provider output
  - blocked by main branch health
  - stuck/zombie

## Open Questions

- Is the production Longhorn worker data volume ReadWriteOnce or
  ReadWriteMany?
- Do we want one shared worker data root for all run pods, or explicit
  workflow affinity to keep a Workflow on the same pod?
- Should main-branch repair use a special shorter workflow chain?
- Should coverage lanes be opt-in for implementation runs and reserved for
  final landing/main health?
- Should performance events be stored in MySQL, structured logs, or both?
- What SLO should we set for:
  - dashboard page switch latency
  - job detail initial load
  - live run artifact refresh
  - poller duration
  - default queue latency
