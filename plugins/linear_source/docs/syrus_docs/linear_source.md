# Linear Source

The `linear_source` plugin (`plugins/linear_source/`) adds Linear as an
`InputSource`: it polls a configured Linear team for open issues and creates
Syrus `Job`s (or `Epic`s, via the same explicit `syrus-epic` body-marker
comment GitHub issues use) from them, so Linear can stay the planning system
of record while Syrus still implements against a GitHub repository.
It is a self-contained Rails engine plugin, installed but disabled by
default (`default_enabled: false`, `disableable: true`, category
`input_source`).

## Configuration

`InputSources::Linear#config_schema` drives the repository's input-source
settings UI (the same generic form other `InputSource` subclasses like
GitHub use):

| Key | Type | Required | Scope | Notes |
|---|---|---|---|---|
| `api_key` | `password` | yes | `credentials` (encrypted) | Linear personal/API key, sent as the bare `Authorization` header value (Linear's convention — no `Bearer`/`token` prefix). |
| `team_id` | `linear_team` | yes | `config` | Depends on `api_key`; the settings UI resolves the picker's options through `GET /api/v1/app/linear/teams`. |
| `label_filter` | `string` | no | `config` | Optional Linear label name — only issues carrying this label are ingested. |

`InputSources::Linear#validate_credentials!` calls Linear's `viewer` GraphQL
query to confirm the key authenticates, then (if `team_id` is already set)
confirms that team appears in the key's accessible `teams` list — a
key that authenticates but can't see the configured team is reported as
invalid rather than silently ingesting nothing.

## Polling and ingestion

`InputSources::Linear#poll!` (invoked by the generic `PollInputSourceJob`,
same as every other `InputSource`) uses `LinearClient#issues` to fetch
cursor-paginated GraphQL results in pages of up to 100 issues. The query is
filtered to the configured team, excludes Linear issues in
`cancelled`/`completed` state, and is additionally filtered server-side by
`label_filter` when set. Pagination is capped at 100 pages; if Linear still
reports another page at that point, or reports another page without an end
cursor, the poll fails instead of silently processing an incomplete result.
Each returned issue then passes through `LinearIngestPolicy.evaluate`, a
second cancelled/completed check — belt-and-suspenders against a state
changing between the GraphQL filter and local processing.

For issues that pass the policy:

- **Dedup** — `dedup_key` is the Linear issue's `id` (stored as `Job
  #external_ref`); an issue that already has an open Syrus Job for this
  input source is skipped rather than re-ingested.
- **Epic markers** — the issue's `description` is parsed with the same
  `EpicMarkerParser` GitHub Source uses. An explicit
  `<!-- syrus-epic: <name> -->` comment creates/finds an `Epic`; an explicit
  `<!-- syrus-epic: #<number> -->` (or `owner/repo#<number>`) comment creates
  a Job as a child of that Epic (or, if the referenced Epic doesn't exist yet
  locally, files the Job as
  `triaging_reason: "pending_epic_ref"` the same way an out-of-order GitHub
  child issue would). Visible prose such as `Epic: #123` is ignored for
  routing. To migrate an older template, wrap the old line in a marker block:
  `<!-- syrus-epic\nEpic: #123\n-->`. Because a Linear issue has no natural
  GitHub URL to dedup an Epic on, Linear-declared Epics are keyed on a synthetic
  `linear:issue:<id>` value in `Epic#github_issue_url` instead of a real,
  clickable URL — deliberately not shaped like a GitHub link so it can't be
  mistaken for one.
- **Plain issues** (no marker) become an ordinary Syrus `Job` with
  `issue_title`/`issue_body` copied from the Linear issue's `title`/
  `description`.

A `429` from any page of Linear's API is treated as a soft rate-limit:
`LinearClient` discards any pages already fetched and returns `nil`; `poll!`
records a *successful* poll (`repository.mark_poll_success!`) rather than an
error, so a temporary rate limit doesn't ingest a partial result or trip the
repository's poll-failure tracking. Any other non-200 response, a GraphQL
`errors` array, or a pagination safety failure raises, which `poll!` records
via `repository.mark_poll_failure!` before re-raising.

## Routes

`GET /api/v1/app/linear/teams?api_key=...` (`Api::V1::App::LinearController
#teams`) is a thin wrapper around `LinearClient#teams`, used by the
config-schema `linear_team` field to populate its picker from a
just-entered, not-yet-saved API key.

## MCP tools / admin pages

None. Linear Source only participates through the generic `InputSource`
polling pipeline and settings UI; it adds no MCP tool sets and no
admin/sidebar pages of its own.

## Operational notes

Configure the team (and, if desired, a label filter) deliberately per
repository so Syrus only imports Linear work meant for automation — Linear
Source has no equivalent of GitHub Source's trigger-label gate beyond the
optional `label_filter`, so an unfiltered team will ingest every open,
non-cancelled/completed issue in that team.
