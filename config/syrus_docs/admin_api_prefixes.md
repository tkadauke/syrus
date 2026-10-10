# Admin API Prefix Ownership

Syrus has two admin API prefixes because the admin React UI and external
operator tooling grew at different speeds. They are not interchangeable.

## Rule

`/api/v1/admin/*` is the operator and automation API. It is token-only,
inherits from `ActionController::API`, returns JSON-only payloads, uses
uniform `{ error: { code, message } }` errors, supports bad-token rate
limiting, and should prefer external-reference lookup parameters such as
`repo=owner/name`, `issue_number`, and `pr_number` when a caller may not know a
database ID.

`/api/v1/app/admin/*` serves the admin UI inside the authenticated app. It is
session-or-token authenticated through the app API stack, has CSRF/session
semantics, and may return page-shaped payloads built around React components:
filter trees, sort descriptors, pagination metadata, sidebar counts, and
control schemas. Admin-only mutations that are only launched from in-app
operator screens, such as stuck-Job repair buttons or Job detail controls,
belong here rather than under the user-facing `/api/v1/app/*` paths.

New externally scriptable operator capabilities belong under
`/api/v1/admin/*`. New admin-screen data fetches or mutations that exist only
to drive React UI state belong under `/api/v1/app/admin/*`. If the same
capability needs both consumers, expose it deliberately on both prefixes and
keep the payload/auth contract for each consumer explicit.

`POST /api/v1/admin/pending_actions/invoke` is the generic operator
automation bridge for `PendingActions` operations. The request names an
`action_key`, a JSON `payload`, and a required `reason`; the API call itself is
the confirmation, so the operation runs synchronously after validation and
records an `AdminAction` audit row with the acting user, payload, reason, and
result. Validation failures and operation-raised `ArgumentError`s return
client errors, not server errors. Actions that intrinsically require a chat
session or persisted `ChatPendingAction` record are rejected before execution
instead of being reported as successfully invoked.

Plugin-declared admin API routes follow the same rule. A plugin route intended
for operator automation should declare the `/api/v1/admin/*` prefix; a plugin
route intended only for the in-app admin UI should declare the
`/api/v1/app/admin/*` prefix.

The generated endpoint inventory lives in
`config/syrus_docs/admin_api_catalog.md`; update it with
`bin/surface-catalogs` after route changes.

The user-facing `/api/v1/app/*` namespace must not grow new inline admin
refusal checks. If an endpoint is admin-only, put it under one of the admin
prefixes. The reviewed exceptions are limited to non-migration compatibility
cases such as the maintenance-task sidebar returning an empty badge payload for
non-admin users and the legacy Job lifecycle timeline endpoint.

## Current reviewed overlap

These capabilities currently exist on both prefixes and should not be expanded
without a deliberate migration choice:

- activity
- backend exceptions
- browser errors
- console controls
- Job dependency override and force-fail controls for in-app repair screens
- MCP tool usage
- overview and stuck queues
- plugin enablement/configuration
- process inventory and kill
- queue introspection and stale-run reaping
- reconciler activity
- restart
- run transcripts
- users
- worker health

The architecture spec snapshots the current core Rails routes and plugin route
metadata on both prefixes. Adding, removing, or moving an admin endpoint must
update that reviewed list so route changes cannot quietly increase the split.

## Gaps implied by the rule

The token-only operator API is missing these existing app-admin capabilities:

- WorkUnit diagnostics;
- settings and secret clearing;
- feature flags;
- retention settings and archive downloads;
- invitations;
- maintenance tasks;
- macOS worker rollout controls;
- platform polling;
- GitHub App installation diagnostics;
- plugin pages, plugin services, and plugin detail pages;
- Kubernetes and MySQL browser surfaces contributed by plugins.

The in-app admin API is missing these existing operator/API-oriented
capabilities:

- Jobs;
- Epics;
- Runs and run artifacts;
- Chats and raw chat transcripts;
- Workflows and workflow control;
- version and live instance metadata;
- scheduled-task surfaces;
- terminal sessions;
- design docs;
- test insights.

Moving or filling these gaps is migration work. Do not migrate endpoints as
part of unrelated feature work; add the new endpoint to the prefix that owns
its consumer, then sequence compatibility or parity separately.
