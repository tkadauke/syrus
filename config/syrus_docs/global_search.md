# Global search

The V2 sidebar search opens `/search` and sends the full-text term as
`query=`. The legacy plain-text `q=` form is still accepted when `query=` is
absent, so old links keep working.

The global search API (`/api/v1/app/search`) returns a payload with `results`,
`filter`, and `controls.filter_schema`. `q=` is now the FilterBar AST parameter
on this route, matching dashboard/list filtering. Result type selection remains
`types[]`; when omitted, search combines Jobs, Epics, Chats, and Tests.

Filtering is applied after the FTS query and preserves FTS relevance order.
Combined results expose common filter chips (`repository_id`, `created_at`,
`updated_at`). Single Job and Epic views expose their existing subject schemas.
Chat and Test views expose only the minimal common filters they support.
Unsupported chips are ignored for result types that do not understand them
rather than failing the whole search.

This phase intentionally has no explicit sort controls or sort URL parameters.
