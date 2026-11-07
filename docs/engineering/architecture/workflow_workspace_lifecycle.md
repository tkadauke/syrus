# Workflow workspace lifecycle evidence

Each Workflow keeps two different kinds of workspace location data:

- `worker_hostname` and `worker_storage_key` are live routing affinity. Resume
  work uses them to return to a worker that can access the mutable checkout.
- `last_workspace_hostname` and `last_workspace_storage_key` are durable
  provenance. Queue repair may clear live affinity, but it must retain these
  last-known values so operators can interpret a missing workspace.

`workspace_lifecycle_state` records the latest durable state. The associated
`WorkflowWorkspaceEvent` timeline records `created`, `ownership_transferred`,
`cleaned_up`, `storage_lost`, and `reconstructed` transitions. Events include
the responsible actor and, where applicable, a reason and the previous owner.
Unlike operational logs, these rows remain associated with the Workflow for
the lifetime of its database record.

Workspace creation records `created` for a new Workflow and `reconstructed`
when durable state or earlier events show that a workspace existed before.
The data migration marks workflows with existing routing affinity as created
and copies their affinity into the last-known columns, so a later rebuild is
classified as reconstruction even though it predates the event timeline.

Worker-loss and dead-resume-queue repairs record `storage_lost` before clearing
live routing affinity. Repairs that only change execution placement preserve
last-known ownership without claiming storage loss. Repeating a repair after
live affinity has already been cleared does not create another loss event.

Cleanup records `cleaned_up` with its actor and reason only after filesystem
removal succeeds. `Workflow#cleanup_workspace!` continues to refuse cleanup
while steps, runs, or spawned processes are active; lifecycle recording does
not bypass that safety check.
