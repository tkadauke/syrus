# Multi-worker behavior

Workers advertise capabilities through `SYRUS_WORKER_CAPABILITIES`, including
OS, architecture, toolchain, and runtime facts. Syrus matches mutable workflow
placement and immutable target requirements against live worker capabilities.
A Run that cannot be placed is blocked with `no_capable_worker`; proposal prose
does not create an implicit requirement.

The queued-Run banner distinguishes a busy compatible queue (**Waiting for a
slot**), no consumer, concurrency blocking, a future schedule, claimed work,
missing RunJob, no live workers, an explicit start blocker, and unknown state.
Use the displayed reason instead of assuming every queued Run is saturation.

`JOB_CONCURRENCY` limits worker threads, while `max_concurrent_agent_runs`
limits agent work instance-wide. Retry from a failed step prefers the worker
that owns the reusable workspace or snapshot; stale affinity is surfaced as a
missing queue consumer rather than silently running against the wrong storage.

## Per-host Run pickup admission

Per-host admission uses `host_admission_policy`; workflow resource admission
uses `workflow_admission_policy`. Admission may defer new work when measured
CPU, memory, or disk pressure exceeds policy, while already-running work
continues. Disabling workflow admission is the emergency kill switch for that
gate, not a worker-capability override. Manual pause prevents new eligible work
from starting until an operator resumes it.

Deployment, queue partitioning, native macOS workers, storage remediation, and
Docker Compose sizing are documented in
[`docs/engineering/operations/multi-worker.md`](../../docs/engineering/operations/multi-worker.md).
Internal routing, search, sampling, relay, and API details are in
[`docs/engineering/architecture/multi-worker.md`](../../docs/engineering/architecture/multi-worker.md).
