# Production debugging

## Establish scope

Start from the affected durable record and timestamp: Job, WorkIntent,
WorkUnit, Workflow, Step, Run, chat session, or deploy. Inspect its state,
failure code, worker ownership, queue, and recent transitions before searching
global logs. This separates a domain blockage from a process outage.

Use Rails console only for read-only inspection until the normal recovery path
is understood. Do not patch AASM columns or queue rows directly. Redact tokens,
prompts, repository secrets, and user data from copied output.

## Kubernetes and processes

Use the configured cluster context and namespace explicitly. Typical read-only
checks are:

```sh
kubectl get deploy,pods,jobs
kubectl describe pod <pod>
kubectl logs <pod> --since=30m
kubectl logs <pod> --previous
```

Check pod events and previous-container logs for restarts. Compare the web and
worker image revisions. For a Run, identify the owning worker before inspecting
its filesystem or child processes; chat/workflow files are worker-local.
Process supervision and runtime services may be plugin-owned, so follow the
owning plugin's operator docs for commands beyond core process inspection.

## Queues and workers

Confirm that the Run's queue is consumed by the deployed worker configuration,
then inspect Solid Queue claimed executions, failed executions, and process
heartbeats. A queued Run can also be intentionally blocked by WorkUnit locks,
urgent-work gates, or `RunQueueResolver` capability placement. Inspect its
`PlannedExecutionRequirement` and live worker capabilities before treating it
as queue starvation.

Queue configuration is mapped in [Queues and databases](../maps/queues-and-databases.md).
New `ApplicationJob` classes must declare a consumed queue; see
[Background job conventions](../conventions/background-jobs-and-queues.md).

## Logs and external boundaries

Correlate timestamps across Rails, worker, sidecar, plugin runtime, GitHub, and
execution-backend logs. Distinguish repository-content outcomes: `Unavailable`
is an outage/fallback signal, not proof that a file is absent. For agentic Runs,
separate provider invocation failure from MCP/tool failure and from a later
grader or push failure.

After identifying the cause, recover through the domain procedure in
[Workflow recovery](workflow-recovery.md), then verify both the durable state
and the newly executing work.
