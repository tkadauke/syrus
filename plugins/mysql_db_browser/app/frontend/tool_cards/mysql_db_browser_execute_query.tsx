import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { CardShell, displayValue, EmptyState, numberValue, Row, StatePill } from "@app/routes/chat/toolCardUi"
import { formatMs, MysqlErrorNotice, parseMysqlError, TableShell, TruncatedNotice, type MysqlError } from "../mysqlToolCard"

// Plugin-owned tool card for mysql_db_browser_execute_query (EPIC-293).
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
  | { kind: "select"; statement: string | null; readOnly: boolean; columns: string[]; rows: Record<string, unknown>[]; rowCount: number; truncated: boolean; durationMs: number | null }

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

  if (outcome.kind === "error") return `Query failed${outcome.error?.message ? `: ${outcome.error.message}` : ""}`
  if (outcome.kind === "write") return `${outcome.affectedRows} row${outcome.affectedRows === 1 ? "" : "s"} affected`
  return `${outcome.rowCount} row${outcome.rowCount === 1 ? "" : "s"}${outcome.truncated ? " (truncated)" : ""}`
}

function renderExpanded(context: ToolCardContext) {
  const outcome = parseOutcome(context)
  if (!outcome) return null

  if (outcome.kind === "error") {
    return (
      <CardShell>
        {outcome.statement ? <Row label="Statement" value={outcome.statement} /> : null}
        {outcome.error ? <MysqlErrorNotice error={outcome.error} /> : <div className="text-red-700 dark:text-red-300">Query failed.</div>}
      </CardShell>
    )
  }

  if (outcome.kind === "write") {
    return (
      <CardShell>
        {outcome.statement ? <Row label="Statement" value={outcome.statement} /> : null}
        <Row label="Read-only" value={outcome.readOnly ? "yes" : "no"} />
        <Row label="Rows affected" value={String(outcome.affectedRows)} />
        {outcome.durationMs != null ? <Row label="Duration" value={formatMs(outcome.durationMs)} /> : null}
      </CardShell>
    )
  }

  if (outcome.rows.length === 0) return <EmptyState>Query returned no rows.</EmptyState>

  return (
    <div className="mt-1 space-y-1">
      <TableShell>
        <table className="w-full text-left text-xs">
          <thead className="bg-gray-50 text-2xs uppercase text-gray-500 dark:bg-gray-900 dark:text-gray-400">
            <tr>
              {outcome.columns.map((column) => (
                <th className="whitespace-nowrap px-2 py-1 font-semibold" key={column} scope="col">{column}</th>
              ))}
            </tr>
          </thead>
          <tbody className="divide-y divide-gray-100 bg-white dark:divide-gray-800 dark:bg-gray-950">
            {outcome.rows.map((row, index) => (
              <tr key={index}>
                {outcome.columns.map((column) => (
                  <td className="whitespace-nowrap px-2 py-1 font-mono text-gray-700 dark:text-gray-300" key={column}>{cellText(row[column])}</td>
                ))}
              </tr>
            ))}
          </tbody>
        </table>
      </TableShell>
      <div className="flex items-center gap-2 text-2xs text-gray-500 dark:text-gray-400">
        <StatePill state={outcome.readOnly ? "read-only" : "read-write"} tone={outcome.readOnly ? "info" : "warning"} />
        {outcome.durationMs != null ? <span>{formatMs(outcome.durationMs)}</span> : null}
      </div>
      {outcome.truncated ? <TruncatedNotice label="Result set" /> : null}
    </div>
  )
}

const executeQueryToolCard: ToolCardRenderer = {
  toolName: "mysql_db_browser_execute_query",
  collapsedSummary,
  renderExpanded
}

export default executeQueryToolCard
