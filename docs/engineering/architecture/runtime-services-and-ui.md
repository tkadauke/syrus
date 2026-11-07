# Runtime services and UI

Business mutations remain in Rails services even when their entry point is
React, a sidecar, the CLI, or a plugin.

## Service boundaries

- `app/services/work_units/` and `app/services/work_definitions/` own launch,
  locks, retry policy, and landing intent; `StepDispatcher` is the execution
  funnel.
- `app/services/workflow_workspace.rb` and checkout services own clone, branch,
  diff, and cleanup operations. Callers do not assemble workspace paths.
- `app/services/repository_content.rb` owns clone-free immutable reads.
- `app/services/agent_providers/` adapt providers; `AgentInvocation` records a
  provider-neutral result and session metadata.
- `app/services/execution/` owns command routing and confinement contracts.
- `app/services/landing_queue/` owns readiness and merge coordination.

## Terminal and preview processes

Terminal sessions and preview apps execute on the worker that owns their
workspace. Rails authorizes and records requests, then routes I/O to that
worker; web processes cannot assume they share its filesystem. Preview startup
uses repository configuration, records process ownership and logs,
health-checks its URL, and terminates the child with its owner. See
`app/services/terminal_sessions/`, `app/services/preview_sessions/`, and the
preview MCP handlers; operator configuration belongs in `config/syrus_docs/`.

## Live delivery

Solid Cable broadcasts after durable commits. React uses events to invalidate
or patch TanStack Query data and remains correct after reload if an event was
missed. Solid Cache accelerates reads but is not workflow truth. Channel code
lives in `app/channels/` and `app/frontend/lib/cable.ts`.

## Browser surfaces

Routes under `app/frontend/routes/` expose Dashboard and Job detail, Epics,
repositories, chat, review and diff views, settings, insights, and admin
operations. Job detail composes Workflow history, Runs, logs, artifacts, PR
state, and optionally WorkUnit diagnostics. Admin surfaces cover workers,
queues, stuck work, WorkUnits, plugins, and MCP coverage.

Searchable lists use the Filters AST and `FilterBar`; saved views deliberately
opt into SmartFolders. Chat tools use registered cards or an explicit coverage
status. Collapsed shared tool-card headers remain one visual line, enforced by
component, browser, and architecture specs. See [Frontend surfaces](frontend.md)
and `app/frontend/routes/chat/tool_cards/`.

## Other clients

The Go CLI under `cli/` and Electron shell under `desktop/` consume the same
authenticated APIs. External chat adapters translate platform identities to
`PlatformIdentity` records, then use the core services in
[Chat and sidecars](chat-and-sidecars.md).
