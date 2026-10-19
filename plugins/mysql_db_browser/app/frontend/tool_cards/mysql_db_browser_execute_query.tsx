import { useState } from "react"
import i18n from "i18next"
import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { Button } from "@app/components/Button"
import { redactToolCardValue } from "@app/toolCardSecurity"
import { TextPreview } from "@app/routes/chat/toolCardMarkdown"
import { CardShell, displayValue, EmptyState, numberValue, Row, StatePill } from "@app/routes/chat/toolCardUi"
import { formatMs, MysqlErrorNotice, parseMysqlError, TableShell, TruncatedNotice, type MysqlError } from "../mysqlToolCard"

const INITIAL_VISIBLE_ROWS = 25
const RESULT_CELL_CLASS = "grid min-w-0 grid-cols-[minmax(5rem,0.35fr)_minmax(0,1fr)] gap-2 align-top px-2 py-1 text-text-secondary sm:table-cell sm:w-48"
const STICKY_RESULT_CELL_CLASS = "sm:sticky sm:left-0 sm:z-[1] sm:bg-white sm:dark:bg-gray-950"

// Plugin-owned tool card for mysql_db_browser_execute_query (the tool-card work).
// Three distinct outcomes share this one payload shape (see
// MysqlDbBrowser::QueryExecutor#run_and_audit): a failed statement
// (`available: false`, `error`), a non-SELECT write (`available: true`,
// carries `affected_rows`, empty columns/rows), and a SELECT/SHOW/DESCRIBE
// result (`available: true`, tabular `columns`/`rows`). All three come
// back as the tool call's normal JSON result_body; only the failed-statement
// outcome also sets the MCP response's `error: true` flag -- core's
// ToolResultBody must still give this card the payload in that case (see
// app/frontend/routes/chat/MessageCards.tsx) or the failure never renders
// through this card's own MysqlErrorNotice.
type QueryOutcome =
  | { kind: "error"; statement: string | null; readOnly: boolean; error: MysqlError | null; durationMs: number | null; generatedAt: string | null }
  | { kind: "write"; statement: string | null; readOnly: boolean; affectedRows: number; durationMs: number | null; generatedAt: string | null }
  | {
      kind: "select"
      statement: string | null
      readOnly: boolean
      columns: string[]
      rows: unknown[][]
      rowCount: number
      truncated: boolean
      durationMs: number | null
      generatedAt: string | null
    }

function parseOutcome(context: ToolCardContext): QueryOutcome | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed) || typeof parsed.available !== "boolean") return null

  const statement = displayValue(parsed.statement)
  const durationMs = numberValue(parsed.duration_ms)
  const generatedAt = displayValue(parsed.generated_at)

  if (parsed.available !== true) {
    return { kind: "error", statement, readOnly: parsed.read_only === true, error: parseMysqlError(parsed.error), durationMs, generatedAt }
  }

  const readOnly = parsed.read_only === true
  const affectedRows = numberValue(parsed.affected_rows)
  if (affectedRows != null) return { kind: "write", statement, readOnly, affectedRows, durationMs, generatedAt }

  if (!Array.isArray(parsed.rows)) return null

  const columns = Array.isArray(parsed.columns) ? parsed.columns.filter((c): c is string => typeof c === "string") : []
  const rows = parsed.rows.flatMap((row) => {
    if (Array.isArray(row)) return [row]
    if (isPlainObject(row)) return [columns.map((column) => row[column])]
    return []
  })

  return {
    kind: "select",
    statement,
    readOnly,
    columns,
    rows,
    rowCount: numberValue(parsed.row_count) ?? rows.length,
    truncated: parsed.truncated === true,
    durationMs,
    generatedAt
  }
}

function cellText(value: unknown): string {
  if (value === null || value === undefined) return "NULL"
  if (typeof value === "string") return value
  if (typeof value === "number" || typeof value === "boolean") return String(value)

  try {
    return JSON.stringify(value)
  } catch {
    return String(value)
  }
}

function inputDetails(context: ToolCardContext) {
  const input = isPlainObject(context.input) ? context.input : {}
  return {
    connectionId: displayValue(input.mysql_connection_id),
    connectionLabel: displayValue(input.mysql_connection_label),
    limit: numberValue(input.limit),
    sql: displayValue(input.sql)
  }
}

function redactedCellText(column: string, value: unknown): string {
  const redacted = redactToolCardValue({ [column]: value })
  return cellText(isPlainObject(redacted) ? redacted[column] : value)
}

function QueryMetadata({ context, outcome }: { context: ToolCardContext; outcome: QueryOutcome }) {
  const input = inputDetails(context)
  const statement = outcome.statement ?? input.sql
  const connectionName = input.connectionLabel ?? (input.connectionId ? t("tool_connection_id", { id: input.connectionId }) : null)

  return (
    <div className="space-y-2">
      {statement ? <TextPreview maxLines={4} text={statement} title={t("tool_statement")} /> : null}
      <div className="grid min-w-0 grid-cols-1 gap-2 sm:grid-cols-2">
        {connectionName ? (
          <div className="min-w-0">
            <div className="text-2xs font-semibold text-text-muted">{t("tool_connection")}</div>
            <a className="break-words font-mono text-xs font-medium text-brand hover:underline" href="/db_browser">
              {connectionName}
            </a>
          </div>
        ) : null}
        {input.limit != null ? <Row label={t("tool_limit")} value={String(input.limit)} /> : null}
        {outcome.generatedAt ? <Row label={t("tool_generated_at")} value={outcome.generatedAt} /> : null}
        {outcome.durationMs != null ? <Row label={t("tool_duration")} value={formatMs(outcome.durationMs)} /> : null}
      </div>
    </div>
  )
}

function CellPreview({ column, value }: { column: string; value: unknown }) {
  return <TextPreview maxLines={2} text={redactedCellText(column, value)} />
}

function QueryRows({ outcome }: { outcome: Extract<QueryOutcome, { kind: "select" }> }) {
  const [showAll, setShowAll] = useState(false)
  const visibleRows = showAll ? outcome.rows : outcome.rows.slice(0, INITIAL_VISIBLE_ROWS)
  const hasMore = outcome.rows.length > INITIAL_VISIBLE_ROWS

  return (
    <>
      <TableShell>
        <table className="block w-full table-fixed text-left text-xs sm:table">
          <thead className="hidden bg-gray-50 text-2xs uppercase text-gray-500 dark:bg-gray-900 dark:text-gray-400 sm:table-header-group">
            <tr>
              {outcome.columns.map((column, columnIndex) => (
                <th
                  className={`w-48 break-words px-2 py-1 font-semibold ${columnIndex === 0 ? "sticky left-0 z-10 bg-gray-50 dark:bg-gray-900" : ""}`}
                  key={columnIndex}
                  scope="col"
                >
                  {column}
                </th>
              ))}
            </tr>
          </thead>
          <tbody className="block space-y-2 bg-white p-2 dark:bg-gray-950 sm:table-row-group sm:space-y-0 sm:p-0">
            {visibleRows.map((row, rowIndex) => (
              <tr className="block rounded border border-border p-2 sm:table-row sm:rounded-none sm:border-0 sm:p-0" key={rowIndex}>
                {outcome.columns.map((column, columnIndex) => (
                  <td className={`${RESULT_CELL_CLASS} ${columnIndex === 0 ? STICKY_RESULT_CELL_CLASS : ""}`} key={columnIndex}>
                    <span className="break-words text-2xs font-semibold text-text-muted sm:hidden">{column}</span>
                    <span className="min-w-0">
                      <CellPreview column={column} value={row[columnIndex]} />
                    </span>
                  </td>
                ))}
              </tr>
            ))}
          </tbody>
        </table>
      </TableShell>
      {hasMore ? (
        <Button onClick={() => setShowAll((value) => !value)} size="sm" variant="secondary">
          {showAll ? t("tool_show_fewer_rows") : t("tool_show_all_rows", { count: outcome.rows.length })}
        </Button>
      ) : null}
    </>
  )
}

function collapsedSummary(context: ToolCardContext) {
  const outcome = parseOutcome(context)
  if (!outcome) return null

  if (outcome.kind === "error") return outcome.error?.message ? t("tool_query_failed_message", { message: outcome.error.message }) : t("tool_query_failed")
  if (outcome.kind === "write") return t("tool_rows_affected", { count: outcome.affectedRows })
  return outcome.truncated ? t("tool_rows_returned_truncated", { count: outcome.rowCount }) : t("tool_rows_returned", { count: outcome.rowCount })
}

function t(key: string, options?: Record<string, unknown>) {
  return i18n.t(`mysql_db_browser:${key}`, options)
}

function renderExpanded(context: ToolCardContext) {
  const outcome = parseOutcome(context)
  if (!outcome) return null

  if (outcome.kind === "error") {
    return (
      <CardShell>
        <QueryMetadata context={context} outcome={outcome} />
        <Row label={t("tool_read_only")} value={outcome.readOnly ? t("yes") : t("no")} />
        {outcome.error ? <MysqlErrorNotice error={outcome.error} /> : <div className="text-red-700 dark:text-red-300">{t("tool_query_failed")}</div>}
      </CardShell>
    )
  }

  if (outcome.kind === "write") {
    return (
      <CardShell>
        <QueryMetadata context={context} outcome={outcome} />
        <Row label={t("tool_read_only")} value={outcome.readOnly ? t("yes") : t("no")} />
        <Row label={t("tool_rows_affected_label")} value={String(outcome.affectedRows)} />
      </CardShell>
    )
  }

  return (
    <div className="mt-1 min-w-0 space-y-2 overflow-hidden">
      <QueryMetadata context={context} outcome={outcome} />
      {outcome.rows.length === 0 ? (
        <div className="space-y-1">
          {outcome.columns.length > 0 ? <div className="break-words font-mono text-xs text-text-muted">{outcome.columns.join(" · ")}</div> : null}
          <EmptyState>{t("tool_query_no_rows")}</EmptyState>
        </div>
      ) : (
        <QueryRows outcome={outcome} />
      )}
      <div className="flex items-center gap-2 text-2xs text-text-muted">
        <StatePill state={outcome.readOnly ? t("allow_writes_disabled") : t("allow_writes_enabled")} tone={outcome.readOnly ? "info" : "warning"} />
        <span>{t("tool_rows_returned", { count: outcome.rowCount })}</span>
      </div>
      {outcome.truncated ? <TruncatedNotice label={t("tool_result_set")} /> : null}
    </div>
  )
}

const executeQueryToolCard: ToolCardRenderer = {
  toolName: "mysql_db_browser_execute_query",
  collapsedSummary,
  renderExpanded
}

export default executeQueryToolCard

// Reviewable sample payloads for the Tool Card Catalog (a later Job) — see
// pluginToolCards.tsx's ToolCardExample. Covers all three outcomes
// QueryExecutor#run_and_audit can return (select, write, error) plus a
// truncated large result set.
export const examples = [
  {
    id: "select_rows",
    label: "SELECT with rows",
    input: { sql: "SELECT id, state, priority FROM jobs WHERE state = 'running' LIMIT 3" },
    parsedResult: {
      available: true,
      read_only: true,
      statement: "SELECT id, state, priority FROM jobs WHERE state = 'running' LIMIT 3",
      columns: ["id", "state", "priority"],
      rows: [
        [71, "running", "medium"],
        [68, "running", "medium"],
        [64, "running", "high"]
      ],
      row_count: 3,
      truncated: false,
      duration_ms: 4.2
    }
  },
  {
    id: "select_truncated_large_result",
    label: "SELECT truncated at row limit (large result)",
    description: "row_count (241) exceeds the returned rows array (100) -- exercises the TruncatedNotice.",
    input: { sql: "SELECT * FROM job_logs" },
    parsedResult: {
      available: true,
      read_only: true,
      statement: "SELECT * FROM job_logs",
      columns: ["id", "chunk"],
      rows: Array.from({ length: 100 }, (_, index) => [index + 1, `log line ${index + 1}`]),
      row_count: 241,
      truncated: true,
      duration_ms: 812.6
    }
  },
  {
    id: "legacy_select_rows",
    label: "Legacy SELECT with object rows",
    description: "Persisted tool results from before positional rows remain renderable.",
    input: { sql: "SELECT id, state FROM jobs LIMIT 1" },
    parsedResult: {
      available: true,
      read_only: true,
      statement: "SELECT id, state FROM jobs LIMIT 1",
      columns: ["id", "state"],
      rows: [{ id: 71, state: "succeeded" }],
      row_count: 1,
      truncated: false,
      duration_ms: 3.1
    }
  },
  {
    id: "write_affected_rows",
    label: "UPDATE with affected rows",
    input: { sql: "UPDATE jobs SET priority = 'high' WHERE id = 71" },
    parsedResult: {
      available: true,
      read_only: false,
      statement: "UPDATE jobs SET priority = 'high' WHERE id = 71",
      affected_rows: 1,
      duration_ms: 1.9
    }
  },
  {
    id: "query_error",
    label: "Error: unknown column",
    description: "available: false with a structured error -- the MCP response also sets result_error true, but the card reads the payload itself either way.",
    input: { sql: "SELECT nonexistent_column FROM jobs" },
    resultError: true,
    parsedResult: {
      available: false,
      statement: "SELECT nonexistent_column FROM jobs",
      error: {
        class: "Mysql2::Error",
        message: "Unknown column 'nonexistent_column' in 'field list'",
        hint: "Check the column exists with describe_table before querying it."
      }
    }
  }
]
