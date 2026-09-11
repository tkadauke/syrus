import i18n from "i18next"
import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { Badge, EmptyState } from "@app/routes/chat/toolCardUi"
import { parseDatabase, TableShell, type MysqlDatabaseRow } from "../mysqlToolCard"

// Plugin-owned tool card for mysql_db_browser_list_databases (the tool-card work).
function databaseRows(context: ToolCardContext): MysqlDatabaseRow[] | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed) || parsed.available !== true || !Array.isArray(parsed.databases)) return null

  return parsed.databases.flatMap((entry) => {
    const row = parseDatabase(entry)
    return row ? [row] : []
  })
}

function collapsedSummary(context: ToolCardContext) {
  const rows = databaseRows(context)
  if (!rows) return null

  return t("tool_databases_count", { count: rows.length })
}

function t(key: string, options?: Record<string, unknown>) {
  return i18n.t(`mysql_db_browser:${key}`, options)
}

function renderExpanded(context: ToolCardContext) {
  const rows = databaseRows(context)
  if (!rows) return null
  if (rows.length === 0) return <EmptyState>{t("tool_no_databases")}</EmptyState>

  return (
    <TableShell>
      <table className="w-full text-left text-xs">
        <thead className="bg-gray-50 text-2xs uppercase text-gray-500 dark:bg-gray-900 dark:text-gray-400">
          <tr>
            <th className="px-2 py-1 font-semibold" scope="col">{t("tool_database")}</th>
            <th className="px-2 py-1 font-semibold" scope="col">{t("tool_character_set")}</th>
            <th className="px-2 py-1 font-semibold" scope="col">{t("tool_collation")}</th>
          </tr>
        </thead>
        <tbody className="divide-y divide-gray-100 bg-white dark:divide-gray-800 dark:bg-gray-950">
          {rows.map((row) => (
            <tr key={row.name}>
              <td className="px-2 py-1 font-mono text-gray-800 dark:text-gray-200">
                {row.name} {row.systemSchema ? <Badge>{t("system_schema_badge")}</Badge> : null}
              </td>
              <td className="px-2 py-1 text-gray-600 dark:text-gray-300">{row.defaultCharacterSet ?? "—"}</td>
              <td className="px-2 py-1 text-gray-600 dark:text-gray-300">{row.defaultCollation ?? "—"}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </TableShell>
  )
}

const listDatabasesToolCard: ToolCardRenderer = {
  toolName: "mysql_db_browser_list_databases",
  collapsedSummary,
  renderExpanded
}

export default listDatabasesToolCard
