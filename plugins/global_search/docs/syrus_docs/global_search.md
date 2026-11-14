# Global search

The V2 sidebar search opens `/search` and sends the full-text term as
`query=`. The legacy plain-text `q=` form is still accepted when `query=` is
absent, so old links keep working.

The global search API (`/api/v1/app/search`) returns `results` and `filter`.
Pass `controls=1` when the caller also needs `controls.types` and
`controls.filter_schema`, or `controls=only` for a controls-only response that
skips result queries. The web page fetches and reuses that lightweight response
rather than resending controls with every search term. `controls.types`
lists the currently enabled selectable result types and their labels. `q=` is
now the FilterBar AST parameter on this route, matching dashboard/list
filtering. Result type selection remains `types[]`; when omitted, search
combines Jobs, Epics, Chats, Repositories, and every enabled plugin-contributed
source such as Tests or Design Docs. Repository results do not use the search
index: an accessible repository matches only when the query is its exact full
slug (for example, `tkadauke/syrus`) or exact repository name (`syrus`),
case-insensitively.
Job and Epic results also match their proposer's handle.

Filtering is applied after the FTS query and preserves FTS relevance order.
Combined results expose common filter chips (`repository_id`, `created_at`,
`updated_at`). Single Job and Epic views expose their existing subject schemas.
Chat and Test views expose `repository_id`, `created_at`, and `updated_at`.
Repository views expose `created_at` and `updated_at`; `repository_id` is not
shown because a Repository result has no parent repository to filter by.
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
The API applies the requested result limit before hydrating records and
serializing result objects. Highlight snippets retain their existing sanitized
HTML rendering in the web client.

Job, Epic, and plugin result rows with canonical identifiers show a copyable
slug next to the type badge (the `CopyableSlug` control also used on dashboards
and detail pages). Hovering `JOB-N` / `EPIC-N` opens the same `JobPreviewCard`
/ `EpicPreviewCard` popup used elsewhere in the app; plugin slugs such as
`DOC-N` use the plugin slug-preview registry. The search API includes a `slug`
field on these results for this purpose. Design Doc rows also surface their
state, repository context, owner, current version, visibility, and updated
timestamp when available, and link to `/design_docs/:id`.
