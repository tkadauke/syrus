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
- [Workflow-step internals](workflow-steps.md) — placement, failure reporting,
  recovery, audit events, and grader command telemetry.
- [App-setting internals](app-settings.md) — diagnostic state, prepared-layer
  caching, and resource-admission mechanics.
- [Feature flags](feature-flags.md) — internal rollout, instrumentation, and
  confinement flags.
- [MCP tool usage](mcp-tool-usage.md) — usage recording, admin diagnostics,
  startup timing, retention, and dispatch attribution.
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
- [Chat internals](chat.md) — turn execution, pending actions, Coding Mode,
  media, and cross-chat implementation details.
- [Multi-worker internals](multi-worker.md) — routing, affinity, search,
  resource sampling, admission, and worker APIs.
- [Metrics](metrics.md) — instrumentation, samplers, cursor mechanics,
  cardinality, and metric declaration.
- [Observability](observability.md) — event sinks, exception streams,
  performance markers, startup phases, and diagnostics.
- [Plugins and extension points](plugins.md) — registry ownership and optional
  subsystem boundaries.
- [Frontend surfaces](frontend.md) — Rails SPA shells, React routes, live
  updates, CLI, and desktop clients.
- [Detailed system reference](system-reference.md) — complete model, poller,
  pipeline, service, plugin, sidecar, UI, and topology inventory.
- [Detailed runtime reference](runtime-reference.md) — trigger chains,
  terminal, scheduled-task, and live-update mechanics.
- [Workflow cancellation attribution](workflow_cancellation_attribution.md)
- [Workspace reuse outcomes](workspace_reuse_outcomes.md)
- [Workflow artifacts](workflow_artifacts.md)
- [Workflow workspace lifecycle](workflow_workspace_lifecycle.md)
- [Permission shadow evaluation](permission_shadow_evaluation.md)
- [Worker activity timeline](worker_activity_timeline.md) — core worker
  activity data and its boundary with the worker-timeline plugin.
- [Work-engine reconciler](work_engine_reconciler.md)
- [Persistent MCP sidecar](persistent_mcp_sidecar.md)
- [Agent conversation](agent_conversation.md)
- [Admin API prefix ownership](admin_api_prefixes.md)
- [Admin API catalog](admin_api_catalog.md) — generated route inventory.
- [Diff review comments](diff_review_comments.md)
- [Connected platforms](connected_platforms.md)
- [Input sources](input_sources.md)
- [Repository feature recommendations](repository_feature_recommendations.md)
- [Coding workspace relay](coding_workspace_relay.md)

Procedures belong in [operations](../operations/README.md), inventories in
[maps](../maps/README.md), and hazards in [pitfalls](../pitfalls/README.md).

Return to the [engineering documentation index](../README.md).
