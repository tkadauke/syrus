import i18n from "i18next"
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

  return t("tool_tables_count", { count: card.tables.length, database: card.database })
}

function t(key: string, options?: Record<string, unknown>) {
  return i18n.t(`mysql_db_browser:${key}`, options)
}

function renderExpanded(context: ToolCardContext) {
  const card = parseCard(context)
  if (!card) return null
  if (card.tables.length === 0) return <EmptyState>{t("tool_no_tables_in_database", { database: card.database })}</EmptyState>

  return (
    <div className="mt-1 space-y-1">
      <TableShell>
        <table className="w-full text-left text-xs">
          <thead className="bg-gray-50 text-2xs uppercase text-gray-500 dark:bg-gray-900 dark:text-gray-400">
            <tr>
              <th className="px-2 py-1 font-semibold" scope="col">{t("tool_table")}</th>
              <th className="px-2 py-1 font-semibold" scope="col">{t("tool_type")}</th>
              <th className="px-2 py-1 font-semibold" scope="col">{t("tool_engine")}</th>
              <th className="px-2 py-1 font-semibold" scope="col">{t("tool_rows_approx")}</th>
              <th className="px-2 py-1 font-semibold" scope="col">{t("tool_data_size")}</th>
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
      {card.truncated ? <TruncatedNotice label={t("tool_table_list")} /> : null}
    </div>
  )
}

const listTablesToolCard: ToolCardRenderer = {
  toolName: "mysql_db_browser_list_tables",
  collapsedSummary,
  renderExpanded
}

export default listTablesToolCard
