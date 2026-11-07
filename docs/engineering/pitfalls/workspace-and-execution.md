# Workspace and execution pitfalls

## Deleting a workspace after one Step

**Symptom:** repair or summary Steps cannot find files after an earlier failure.
**Cause:** cleanup was attached to a Run/Step `ensure` instead of Workflow
terminal state. **Prevention:** treat `WorkflowWorkspace` as Workflow-owned;
schedule terminal cleanup and let the prune job handle retained directories.

## Reading live files from a distributed grader

**Symptom:** a grader reports a different revision depending on worker timing.
**Cause:** it read the mutable workflow checkout rather than its recorded
`WorkflowSourceSnapshot`. **Prevention:** detached snapshot checkout is the
grader source of truth; publish a new snapshot for new source.

## Treating worker files as web-local

**Symptom:** chat attachment or preview works on one process but 404s through
the web pod. **Cause:** chat/workflow files and preview children live on the
owning worker. **Prevention:** route access through worker-aware workspace and
preview services.

## Bypassing execution routing

**Symptom:** a command ignores confinement, remote execution, or workload
fail-closed policy. **Cause:** a caller invoked a local subprocess directly.
**Prevention:** send supported workload requests through `Execution::Router`;
keep backend and confinement decisions in provider contracts.

## Inferring placement from prose

**Symptom:** work starts on an incompatible worker or blocks unexpectedly.
**Cause:** capability needs were mentioned in a prompt but absent from
`PlannedExecutionRequirement`. **Prevention:** declare project, target, source,
and capability dimensions explicitly and inspect `RunQueueResolver` output.
