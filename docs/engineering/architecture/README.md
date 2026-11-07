# Architecture

These pages describe current subsystem boundaries, ownership, data flow, and
invariants. [ARCHITECTURE.md](../../../ARCHITECTURE.md) remains the canonical
system-wide overview and routes here for detail.

- [Domain model and work engine](domain-model-and-work-engine.md) — durable
  records, state machines, access control, and launch ownership.
- [Workflow execution](workflow-execution.md) — triggers, step chains,
  dispatch, providers, graders, and landing.
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

Procedures belong in [operations](../operations/README.md), inventories in
[maps](../maps/README.md), and hazards in [pitfalls](../pitfalls/README.md).

Return to the [engineering documentation index](../README.md).
