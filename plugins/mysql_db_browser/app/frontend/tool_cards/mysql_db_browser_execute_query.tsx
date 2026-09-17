import i18n from "i18next"
import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { CardShell, displayValue, EmptyState, numberValue, Row, StatePill } from "@app/routes/chat/toolCardUi"
import { formatMs, MysqlErrorNotice, parseMysqlError, TableShell, TruncatedNotice, type MysqlError } from "../mysqlToolCard"

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
  | { kind: "error"; statement: string | null; error: MysqlError | null; durationMs: number | null }
  | { kind: "write"; statement: string | null; readOnly: boolean; affectedRows: number; durationMs: number | null }
  | {
      kind: "select"
      statement: string | null
      readOnly: boolean
      columns: string[]
      rows: Record<string, unknown>[]
      rowCount: number
      truncated: boolean
      durationMs: number | null
    }

function parseOutcome(context: ToolCardContext): QueryOutcome | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed) || typeof parsed.available !== "boolean") return null

  const statement = displayValue(parsed.statement)
  const durationMs = numberValue(parsed.duration_ms)

  if (parsed.available !== true) {
    return { kind: "error", statement, error: parseMysqlError(parsed.error), durationMs }
  }

  const readOnly = parsed.read_only === true
  const affectedRows = numberValue(parsed.affected_rows)
  if (affectedRows != null) return { kind: "write", statement, readOnly, affectedRows, durationMs }

  if (!Array.isArray(parsed.rows)) return null

  const columns = Array.isArray(parsed.columns) ? parsed.columns.filter((c): c is string => typeof c === "string") : []
  const rows = parsed.rows.filter(isPlainObject) as Record<string, unknown>[]

  return {
    kind: "select",
    statement,
    readOnly,
    columns,
    rows,
    rowCount: numberValue(parsed.row_count) ?? rows.length,
    truncated: parsed.truncated === true,
    durationMs
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
        {outcome.statement ? <Row label={t("tool_statement")} value={outcome.statement} /> : null}
        {outcome.error ? <MysqlErrorNotice error={outcome.error} /> : <div className="text-red-700 dark:text-red-300">{t("tool_query_failed")}</div>}
      </CardShell>
    )
  }

  if (outcome.kind === "write") {
    return (
      <CardShell>
        {outcome.statement ? <Row label={t("tool_statement")} value={outcome.statement} /> : null}
        <Row label={t("tool_read_only")} value={outcome.readOnly ? t("yes") : t("no")} />
        <Row label={t("tool_rows_affected_label")} value={String(outcome.affectedRows)} />
        {outcome.durationMs != null ? <Row label={t("tool_duration")} value={formatMs(outcome.durationMs)} /> : null}
      </CardShell>
    )
  }

  if (outcome.rows.length === 0) return <EmptyState>{t("tool_query_no_rows")}</EmptyState>

  return (
    <div className="mt-1 space-y-1">
      <TableShell>
        <table className="w-full text-left text-xs">
          <thead className="bg-gray-50 text-2xs uppercase text-gray-500 dark:bg-gray-900 dark:text-gray-400">
            <tr>
              {outcome.columns.map((column) => (
                <th className="whitespace-nowrap px-2 py-1 font-semibold" key={column} scope="col">
                  {column}
                </th>
              ))}
            </tr>
          </thead>
          <tbody className="divide-y divide-gray-100 bg-white dark:divide-gray-800 dark:bg-gray-950">
            {outcome.rows.map((row, index) => (
              <tr key={index}>
                {outcome.columns.map((column) => (
                  <td className="whitespace-nowrap px-2 py-1 font-mono text-gray-700 dark:text-gray-300" key={column}>
                    {cellText(row[column])}
                  </td>
                ))}
              </tr>
            ))}
          </tbody>
        </table>
      </TableShell>
      <div className="flex items-center gap-2 text-2xs text-gray-500 dark:text-gray-400">
        <StatePill state={outcome.readOnly ? t("allow_writes_disabled") : t("allow_writes_enabled")} tone={outcome.readOnly ? "info" : "warning"} />
        {outcome.durationMs != null ? <span>{formatMs(outcome.durationMs)}</span> : null}
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
        { id: 71, state: "running", priority: "medium" },
        { id: 68, state: "running", priority: "medium" },
        { id: 64, state: "running", priority: "high" }
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
      rows: Array.from({ length: 100 }, (_, index) => ({ id: index + 1, chunk: `log line ${index + 1}` })),
      row_count: 241,
      truncated: true,
      duration_ms: 812.6
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
