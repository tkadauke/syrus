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
control schemas.

New externally scriptable operator capabilities belong under
`/api/v1/admin/*`. New admin-screen data fetches or mutations that exist only
to drive React UI state belong under `/api/v1/app/admin/*`. If the same
capability needs both consumers, expose it deliberately on both prefixes and
keep the payload/auth contract for each consumer explicit.

Plugin-declared admin API routes follow the same rule. A plugin route intended
for operator automation should declare the `/api/v1/admin/*` prefix; a plugin
route intended only for the in-app admin UI should declare the
`/api/v1/app/admin/*` prefix.

## Current reviewed overlap

These capabilities currently exist on both prefixes and should not be expanded
without a deliberate migration choice:

- activity
- backend exceptions
- browser errors
- console controls
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
