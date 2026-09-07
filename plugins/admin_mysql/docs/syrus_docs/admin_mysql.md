# Admin MySQL

The `admin_mysql` plugin (`plugins/admin_mysql/`) gives operators a live,
read-mostly view of the MySQL server backing a Syrus instance: process list,
connection pressure, buffer/InnoDB variables, slow-query-log configuration,
Performance Schema statement digests, and a targeted `KILL QUERY` action. It
is a self-contained Rails engine plugin, installed but disabled by default
(`default_enabled: false`, `disableable: true`, category `observability`).
Unlike `mysql_db_browser`, this plugin only ever inspects Syrus's *own*
database connection (`ActiveRecord::Base.connection`) — it has no concept of
external connections.

## Configuration

No credentials or config schema. The plugin works against whatever
`ActiveRecord::Base.connection` Syrus is already using; `AdminMysql.mysql?`
(`Inspector.mysql?`) checks that the adapter name includes `"mysql"` and
every entry point (`Inspector#snapshot`, `#kill_query`, both admin pages,
both MCP tool sets) raises/hides itself when the check fails. On a
SQLite-backed dev/test instance the plugin has nothing to show, so `AdminPages
.admin_pages` returns `[]` and both MCP tool sets report themselves
unavailable — the plugin is a no-op rather than an error.

`suggests_enabling` nudges an admin to turn the plugin on when
`Syrus::PluginSignals#database_adapters` (stamped by `Steps::Prepare`/
`RepoPluginDetector`) reports a MySQL adapter in use.

## Admin page

**Admin → MySQL** (`/admin/mysql`, group `observability`) renders
`AdminMysql::Inspector#snapshot`, fetched from `GET /api/v1/app/admin/mysql`
(mirrored at `GET /api/v1/admin/mysql` for the external Bearer-token admin
API):

- `connection_summary` — threads connected/running, max used connections vs.
  `max_connections`, sleeping-connection count, aborted connects, and
  `wait_timeout`/`interactive_timeout`.
- `variables` / `status` — a fixed allowlist of `SHOW VARIABLES`/`SHOW GLOBAL
  STATUS` values (version, InnoDB buffer pool/log/redo settings, flush/sync
  settings, slow-query-log settings, and InnoDB row-lock/fsync counters).
- `process_list` — `SHOW FULL PROCESSLIST`, sorted running-first then by
  longest-running, capped at `limit` (default 50, max 200), with `Info`
  truncated to 1000 bytes.
- `statement_digests` — top statements from
  `performance_schema.events_statements_summary_by_digest`, scoped to the
  current database, ordered by total wait time.
- `slow_log` — `mysql.slow_log` config (`slow_query_log`, `log_output`,
  `long_query_time`); row data is loaded only when `include_slow_log` is
  explicitly requested, since reading `mysql.slow_log` can be expensive on a
  busy instance.

Every diagnostic `SELECT` carries a `MAX_EXECUTION_TIME` hint (1000ms for
process/digest queries, 250ms for slow-log rows) so a stuck query in the
inspected server can't hang the admin page itself. A missing GRANT (e.g. no
`SELECT` on `performance_schema.events_statements_summary_by_digest` or
`mysql.slow_log`) degrades that one section to
`{ available: false, error: { class, message, hint, setup_sql } }` with the
exact `GRANT`/`SET GLOBAL` statement needed, rather than failing the whole
snapshot.

`POST /api/v1/app/admin/mysql/kill_query` (mirrored at
`/api/v1/admin/mysql/kill_query`) runs `KILL QUERY <thread_id>` against a
`PROCESSLIST.Id` — it stops the query, not the connection.

## MCP tools

Two tools, shared between the workflow and chat tool sets
(`AdminMysql::WorkflowToolSet` delegates to `AdminMysql::ChatToolSet` at
`tier: :essential`):

- `admin_mysql_status(limit?)` — same payload as the admin page's snapshot.
- `admin_mysql_kill_query(thread_id)` — same as the admin page's kill action.

Availability differs by surface:

- **Workflow tools** — `AdminMysql::WorkflowToolSet.available_for?` requires
  `AdminMysql.mysql?` and `McpToolPolicy.syrus_repository?` (the Job's
  repository is `tkadauke/syrus` or a registered fork), and
  `available_for_context?` further restricts it to the `WORKFLOW_IMPLEMENT`
  agent role. In other words, only implement-step agents working on Syrus
  itself get these tools — not arbitrary customer-repository workflows.
- **Chat tools** — `AdminMysql::ChatToolSet.available_for?` requires the
  chat's user to be an admin and `AdminMysql.mysql?`, with no repository
  restriction, so any admin's chat session can inspect/kill queries once the
  plugin is enabled on a MySQL instance.

## Operational notes

The plugin reads live database state and can terminate queries, so treat it
as an operator/admin-only surface: keep it disabled on SQLite installations
(there is nothing for it to show) and enable it deliberately on MySQL-backed
production or staging instances that need in-app diagnosis instead of
shelling into the database pod.
