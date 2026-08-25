# MySQL DB Browser

The `mysql_db_browser` plugin (`plugins/mysql_db_browser/`) lets an operator
register connections to arbitrary external MySQL databases and browse/query
them in a grid-first, Sequel Pro/TablePlus-style browser. It is a
self-contained Rails engine plugin, installed but disabled by default
(`default_enabled: false`, `disableable: true`, category `observability`),
gated behind the `mysql_db_browser` instance-wide `Feature` flag. Every
controller action additionally checks `MysqlDbBrowser.enabled?` (flag AND
plugin record both enabled) and `Current.user.admin?`, so the whole surface
is admin-only.

## Connections (`MysqlConnection`)

`app/models/mysql_connection.rb` stores `label`, `host`, `port`, `username`,
an optional `default_database`, and encrypted `credentials`
(`encrypts :credentials, :json`, same pattern as `InputSource#credentials`) -
the plaintext password lives only inside that encrypted JSON blob, never in
a plain column. Two independent boolean opt-ins, both default `false`:

- `agentic_access_enabled` - reserved for a future job that wires this
  connection into `mcp_tool_set`/`chat_mcp_tool_set` so workflow/chat agents
  can query it directly. Not yet consumed by anything.
- `allow_writes` - see Read-only guardrails below.

Managed from **Admin → DB Browser** (`/db_browser`, admin-only sidebar page,
`MysqlDbBrowser::SidebarPages`) via `GET/POST/PATCH/DELETE
/api/v1/app/admin/mysql_connections` and a connect-test endpoint
(`POST .../test` or `.../:id/test`, backed by `MysqlDbBrowser::ConnectionTester`)
that never persists a draft connection.

## Schema browsing

`MysqlDbBrowser::SchemaInspector` introspects an explicit external
`Mysql2::Client` (built from the connection's decrypted credentials) rather
than `ActiveRecord::Base.connection` - it mirrors `AdminMysql::Inspector`'s
safe-section/timeout-hint/truncation design but is not tied to Syrus's own
database. `GET .../mysql_connections/:id/schema` lists databases (always
including the four MySQL system schemas - `information_schema`,
`performance_schema`, `mysql`, `sys` - flagged via `system_schema: true`, not
special-cased); `.../schema/:database/tables` lists tables; `.../tables/:table`
returns table info, columns, and indexes. Every section degrades to
`{ available: false, error: { class, message, hint? } }` on a MySQL error
(most commonly a GRANT denial) instead of failing the whole request.

## Content / Query / Live tabs

The DB Browser page (`MysqlConnections.tsx`) is a dual-mode browser per the
Sequel Pro/TablePlus UX: a **Browse** tab (the schema tree above, with a
selected table opening **Content** - a sortable results grid, the default -
and **Structure** - the columns/indexes view), plus two connection-level
tabs, **Query** and **Live**.

- **Content** - `GET .../schema/:database/tables/:table/content` builds
  `SELECT * FROM \`db\`.\`table\` [WHERE ...] ORDER BY ... LIMIT n+1 OFFSET m`
  server-side and returns it alongside a `filter_schema`
  (`MysqlDbBrowser::FilterSchemaBuilder`, derived from the table's
  introspected columns: MySQL type -> bucket -> operator set - `tinyint(1)`
  -> boolean, other numerics -> number, `date`/`datetime`/`timestamp`/`time`/`year`
  -> date, `enum` -> enum with parsed allowed values, everything else ->
  string) so the frontend can drive the existing `FilterBar` component
  (`app/frontend/components/FilterBar.tsx`) with no new filter-chip UI.
  `MysqlDbBrowser::FilterTreeSqlCompiler` compiles the FilterBar `FilterTree`
  (decoded from the `q` param via `Filters::QueryParam.decode` /
  `Filters::Ast.parse` - the same wire format every other FilterBar consumer
  uses) into a WHERE fragment, escaping every value through the same
  `Mysql2::Client` that runs the query and quoting identifiers with doubled
  backticks. Pagination is Prev/Next only (an exact `COUNT(*)` on an
  arbitrary external table could be an unbounded full scan, which would
  defeat the row-limit/timeout guardrails); `has_more` is derived by
  requesting `per_page + 1` rows.
- **Query** - a raw SQL editor running through `POST .../mysql_connections/:id/query`
  (body `{ mysql_query: { sql } }`).
- **Live** - the same raw-SQL endpoint with three canned, `refetchInterval:
  10_000` statements generalizing `AdminMysql.tsx`'s process-list/global-status/
  slow-log views (built for Syrus's own database) to any connection: `SELECT
  * FROM information_schema.PROCESSLIST`, `SELECT ... FROM
  performance_schema.global_status`, `SELECT ... FROM mysql.slow_log`. These
  are ordinary SELECTs against schemas the schema explorer already treats as
  browsable, so no bespoke diagnostics controller/service was needed.

## Query builder

The **Query Builder** sub-tab (alongside Content/Structure for a selected
table) is a Metabase-notebook-style no-code sequence of steps that compiles
to SQL and runs through the same guardrailed executor as Content/Query,
rendering into the same results grid. Steps:

- **Table** - a picker (the `button[aria-haspopup=listbox]` +
  `div[role=listbox]` dropdown pattern from `ChatModeSelector`/
  `ChatModelSelector` in `Compose.tsx`, generalized into
  `MysqlPickerDropdown.tsx`) defaulting to the table selected in the schema
  tree, changeable to any table in the same database.
- **Columns or Summarize** - either a raw column checklist (unchecked =
  `SELECT *`), or an aggregate/group-by summary: repeatable
  `{function, column, alias}` rows (`count`/`sum`/`avg`/`min`/`max`, `count`
  additionally accepts `*`) plus a group-by column checklist.
- **Join** - optional, single join, picked from the base table's foreign
  keys as surfaced by the schema explorer (`SchemaInspector#table`'s new
  `foreign_keys` section - see below) rather than a free-form table+column
  picker. Selecting a relationship (either its outgoing or incoming
  direction) fills in the join table and both join columns; inner/left is a
  separate toggle (left by default).
- **Filter** - `FilterBar`, exactly like the Content tab, driven by a
  `filter_schema` the server derives from the base table's columns (and the
  joined table's, qualified `table.column`, when a join is present) via
  `FilterSchemaBuilder.build(columns, table_prefix:)`.
- **Sort** - a column (or, in Summarize mode, a group-by column or
  aggregation alias) plus direction.
- **Limit** - 1-500, default 100.

`GET .../mysql_connections/:id/schema/:database/query_builder?spec=<json>&q=<filter>`
(`MysqlQueryController#query_builder`) parses the JSON `spec`, fetches real
column lists for the base table (and join table, if any) via
`SchemaInspector`, and hands both to
`MysqlDbBrowser::QueryBuilderCompiler`, which validates every table/column/
aggregation-function/join-type/sort reference against that real schema
before compiling a single SELECT (raising `InvalidSpec`, rendered as `422
invalid_spec`, on anything unrecognized) - identifiers are still quoted
through `SqlIdentifier.quote` (shared with `FilterTreeSqlCompiler` and the
Content tab's raw SELECT builder; now dot-aware, so `table.column` refs
quote each segment independently) so nothing can break out of identifier
position even if validation were somehow bypassed. Column references
throughout the spec (`columns`, `aggregations[].column`, `group_by`,
`join.from_column`/`join.to_column`, `sort.column`) are always
`"table.column"` qualified strings - the frontend always knows which table
a picker belongs to, so the compiler has one column-resolution code path
regardless of whether a join is present. The endpoint is auto-run
(declarative `useQuery`, keyed on the JSON-stringified spec plus the `q`
filter param) the same way the Content tab is - there is no manual "Run"
step - so the filter step's `filter_schema` is available as soon as a valid
table/column selection exists, before the operator has added any filter.
The response includes the compiled `statement` (already part of
`QueryExecutor`'s result payload), rendered read-only above the results
grid so the operator can see exactly what ran.

`SchemaInspector#table`'s new `foreign_keys` section returns both
directions symmetrically: `{constraint_name, direction, from_table,
from_column, to_table, to_column}`, where `from_table`/`from_column` is
always the FK-holding side and `to_table`/`to_column` is what it
references, regardless of whether the row is "outgoing" (this table holds
the FK) or "incoming" (another table's FK points back at this one). The
Structure tab renders this alongside Columns/Indexes; the query builder's
join step filters it to rows touching the currently selected table and
derives the join spec from whichever side isn't that table.

## Read-only guardrails and audit log

`MysqlDbBrowser::QueryExecutor` is the single execution path for both the
Query tab and the Content tab (the latter via `#execute_select`, which yields
the connected client so the caller can build the final SQL with the same
escaper before running it). Guardrails, mirroring `AdminMysql::Inspector`:

- **Read-only by default.** A statement is accepted unmodified only if it
  matches `/\A(SELECT|WITH)\b/i`; anything else (INSERT/UPDATE/DELETE/DDL/...)
  is rejected with `403 write_not_allowed` unless the connection's
  `allow_writes` is `true`. The check runs before opening a connection.
- **Statement-timeout hint** - literal `SELECT` statements get
  `SELECT /*+ MAX_EXECUTION_TIME(5000) */ ...` prepended (skipped for `WITH`
  CTEs, since the hint must immediately follow `SELECT`).
- **Row-limit clamping** - SELECTs stream (`stream: true, cache_rows: false`)
  and stop after `limit + 1` rows (`abandon_results!` on early stop) rather
  than buffering an entire result set, reporting `truncated: true` when hit.
- **Value truncation** - string cell values over 2,000 bytes are cut with
  `String#safe_byteslice` (never raw `byteslice`, per the UTF-8 truncation
  convention) and suffixed with `…`.
- **Structured GRANT-error hints** - a query-time `Mysql2::Error` (bad SQL,
  missing privileges, timeout) doesn't raise; it comes back as
  `{ available: false, error: { class, message, hint? } }` with a `200`, so
  the Query/Content tabs can show it inline. A connection-time failure (bad
  host/credentials) raises `Unavailable`, rendered as `502
  connection_unavailable`.
- **Audit log** - every attempt, successful, rejected, or failed, is recorded
  to `MysqlQueryAudit` (`mysql_connection`, `user`, `statement`, `read_only`,
  `success`, `row_count`, `error_message`, `duration_ms`). Audit persistence
  failures are logged, not raised - they never block returning query results
  to the operator.
