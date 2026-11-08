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

## Restoring a partial plugin-backed registry in tests

**Symptom:** plugin actions disappear only after an unrelated spec runs.
**Cause:** a test snapshots a global registry before bundled plugin
registrations are loaded, then restores that incomplete snapshot.
**Prevention:** force-load plugin registrations before snapshotting and restore
the complete registry in cleanup.

## Reusing snapshot-time landing memoization

**Symptom:** the final locked landing check accepts state that changed after the
queue snapshot. **Cause:** one `LandingQueueProcessor` instance reused memoized
urgent-work, dependency, or Epic state. **Prevention:** invalidate those caches
before the final eligibility check under the landing lock.

## Losing grader failure evidence with worker-local output

**Symptom:** a failed grader has only a truncated preview or no actionable
failed example after its worker is gone. **Cause:** diagnosis depended on live
logs or workspace files. **Prevention:** persist structured failure summaries,
machine-readable test output, timeout markers, and failed-example locations;
prefer that durable evidence over scraped previews.

## Marking a non-triggering group-chat message in flight

**Symptom:** a group chat appears busy even though no addressed agent started a
turn. **Cause:** one message-ingress or queued-promotion path set
`turn_in_flight` without applying `ChatSession#should_trigger_agent?` to the
resolved mentions. **Prevention:** every user-message creation path, including
scheduled and external ingress, must derive both turn dispatch and in-flight
state from the same trigger predicate.
