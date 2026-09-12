# Global search

The V2 sidebar search opens `/search` and sends the full-text term as
`query=`. The legacy plain-text `q=` form is still accepted when `query=` is
absent, so old links keep working.

The global search API (`/api/v1/app/search`) returns a payload with `results`,
`filter`, `controls.types`, and `controls.filter_schema`. `controls.types`
lists the currently enabled selectable result types and their labels. `q=` is
now the FilterBar AST parameter on this route, matching dashboard/list
filtering. Result type selection remains `types[]`; when omitted, search
combines Jobs, Epics, Chats, and every enabled plugin-contributed source such
as Tests or Design Docs.

Filtering is applied after the FTS query and preserves FTS relevance order.
Combined results expose common filter chips (`repository_id`, `created_at`,
`updated_at`). Single Job and Epic views expose their existing subject schemas.
Chat and Test views expose `repository_id`, `created_at`, and `updated_at`.
Design Doc views expose the Design Docs filter subject, including state,
visibility, repository, owner, and timestamp chips.
For chats, `repository_id` filters by the repository(ies) attached to the
message's chat session (via `ChatAttachment`), since `ChatMessage` has no
`repository_id` column of its own; chat search results also now surface a
`repository_slug` (the session's first attached repository) alongside the
existing job/epic/test repository slugs. Unsupported chips are ignored for
result types that do not understand them rather than failing the whole
search.

This phase intentionally has no explicit sort controls or sort URL parameters.

Job, Epic, and plugin result rows with canonical identifiers show a copyable
slug next to the type badge (the `CopyableSlug` control also used on dashboards
and detail pages). Hovering `JOB-N` / `EPIC-N` opens the same `JobPreviewCard`
/ `EpicPreviewCard` popup used elsewhere in the app; plugin slugs such as
`DOC-N` use the plugin slug-preview registry. The search API includes a `slug`
field on these results for this purpose. Design Doc rows also surface their
state, repository context, owner, current version, visibility, and updated
timestamp when available, and link to `/design_docs/:id`.
