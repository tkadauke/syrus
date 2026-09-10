import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { displayValue, EmptyState } from "@app/routes/chat/toolCardUi"
import { formatBytes } from "@app/lib/format"
import { parseTableSummary, TableShell, TruncatedNotice, type MysqlTableRow } from "../mysqlToolCard"

// Plugin-owned tool card for mysql_db_browser_list_tables (the tool-card work).
type TablesCard = { database: string; truncated: boolean; tables: MysqlTableRow[] }

function parseCard(context: ToolCardContext): TablesCard | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed) || parsed.available !== true || !Array.isArray(parsed.tables)) return null

  const database = displayValue(parsed.database)
  if (!database) return null

  return {
    database,
    truncated: parsed.truncated === true,
    tables: parsed.tables.flatMap((entry) => { const row = parseTableSummary(entry); return row ? [row] : [] })
  }
}

function collapsedSummary(context: ToolCardContext) {
  const card = parseCard(context)
  if (!card) return null

  return `${card.tables.length} table${card.tables.length === 1 ? "" : "s"} in ${card.database}`
}

function renderExpanded(context: ToolCardContext) {
  const card = parseCard(context)
  if (!card) return null
  if (card.tables.length === 0) return <EmptyState>No tables in {card.database}.</EmptyState>

  return (
    <div className="mt-1 space-y-1">
      <TableShell>
        <table className="w-full text-left text-xs">
          <thead className="bg-gray-50 text-2xs uppercase text-gray-500 dark:bg-gray-900 dark:text-gray-400">
            <tr>
              <th className="px-2 py-1 font-semibold" scope="col">Table</th>
              <th className="px-2 py-1 font-semibold" scope="col">Type</th>
              <th className="px-2 py-1 font-semibold" scope="col">Engine</th>
              <th className="px-2 py-1 font-semibold" scope="col">Rows (approx)</th>
              <th className="px-2 py-1 font-semibold" scope="col">Data size</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-gray-100 bg-white dark:divide-gray-800 dark:bg-gray-950">
            {card.tables.map((row) => (
              <tr key={row.name}>
                <td className="px-2 py-1 font-mono text-gray-800 dark:text-gray-200" title={row.comment ?? undefined}>{row.name}</td>
                <td className="px-2 py-1 text-gray-600 dark:text-gray-300">{row.type ?? "—"}</td>
                <td className="px-2 py-1 text-gray-600 dark:text-gray-300">{row.engine ?? "—"}</td>
                <td className="whitespace-nowrap px-2 py-1 text-gray-600 dark:text-gray-300">{row.approxRowCount != null ? row.approxRowCount.toLocaleString() : "—"}</td>
                <td className="whitespace-nowrap px-2 py-1 text-gray-600 dark:text-gray-300">{formatBytes(row.dataLengthBytes)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </TableShell>
      {card.truncated ? <TruncatedNotice label="Table list" /> : null}
    </div>
  )
}

const listTablesToolCard: ToolCardRenderer = {
  toolName: "mysql_db_browser_list_tables",
  collapsedSummary,
  renderExpanded
}

export default listTablesToolCard
