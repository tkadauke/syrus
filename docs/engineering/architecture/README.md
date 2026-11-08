# Architecture

These pages describe current subsystem boundaries, ownership, data flow, and
invariants. [ARCHITECTURE.md](../../../ARCHITECTURE.md) remains the canonical
system-wide overview and routes here for detail.

- [Domain model and work engine](domain-model-and-work-engine.md) — durable
  records, state machines, access control, and launch ownership.
- [WorkUnit path ownership](work-unit-path-ownership.md) — current scheduler,
  landing, and reconciler launch ownership contract.
- [Workflow execution](workflow-execution.md) — triggers, step chains,
  dispatch, providers, graders, and landing.
- [Scheduling and polling](scheduling-and-polling.md) — recurring entry points,
  ingestion, scheduled work, external PRs, and stale-run repair.
- [Runtime services and UI](runtime-services-and-ui.md) — service boundaries,
  terminal and preview processes, live delivery, and operator surfaces.
- [Workspace lifecycle](workspace-lifecycle.md) — mutable checkouts, immutable
  grader snapshots, placement, and cleanup.
- [Repository content](repository-content.md) — immutable revision reads,
  provider fallback, and caching.
- [Chat and sidecars](chat-and-sidecars.md) — chat sessions, MCP sidecars,
  previews, and external platform chat.
- [Plugins and extension points](plugins.md) — registry ownership and optional
  subsystem boundaries.
- [Frontend surfaces](frontend.md) — Rails SPA shells, React routes, live
  updates, CLI, and desktop clients.
- [Detailed system reference](system-reference.md) — complete model, poller,
  pipeline, service, plugin, sidecar, UI, and topology inventory.
- [Detailed runtime reference](runtime-reference.md) — trigger chains,
  terminal, scheduled-task, and live-update mechanics.

Procedures belong in [operations](../operations/README.md), inventories in
[maps](../maps/README.md), and hazards in [pitfalls](../pitfalls/README.md).

Return to the [engineering documentation index](../README.md).
