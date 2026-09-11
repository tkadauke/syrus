import i18n from "i18next"
import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { EmptyState } from "@app/routes/chat/toolCardUi"
import { AccessPill, parseConnection, TableShell, type MysqlConnectionRow } from "../mysqlToolCard"

// Plugin-owned tool card for mysql_db_browser_list_connections (the tool-card work).
// The payload is already safe metadata only (see
// MysqlDbBrowser::AgenticAccess::SAFE_METADATA_FIELDS -- no host, username,
// or password), so this card renders it as-is.
function connectionRows(context: ToolCardContext): MysqlConnectionRow[] | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed) || !Array.isArray(parsed.mysql_connections)) return null

  return parsed.mysql_connections.flatMap((entry) => {
    const row = parseConnection(entry)
    return row ? [row] : []
  })
}

function collapsedSummary(context: ToolCardContext) {
  const rows = connectionRows(context)
  if (!rows) return null

  return t("tool_connections_count", { count: rows.length })
}

function t(key: string, options?: Record<string, unknown>) {
  return i18n.t(`mysql_db_browser:${key}`, options)
}

function renderExpanded(context: ToolCardContext) {
  const rows = connectionRows(context)
  if (!rows) return null
  if (rows.length === 0) return <EmptyState>{t("tool_no_connections")}</EmptyState>

  return (
    <TableShell>
      <table className="w-full text-left text-xs">
        <thead className="bg-gray-50 text-2xs uppercase text-gray-500 dark:bg-gray-900 dark:text-gray-400">
          <tr>
            <th className="px-2 py-1 font-semibold" scope="col">{t("tool_label")}</th>
            <th className="px-2 py-1 font-semibold" scope="col">{t("tool_default_database")}</th>
            <th className="px-2 py-1 font-semibold" scope="col">{t("tool_agentic_access")}</th>
            <th className="px-2 py-1 font-semibold" scope="col">{t("tool_writes")}</th>
          </tr>
        </thead>
        <tbody className="divide-y divide-gray-100 bg-white dark:divide-gray-800 dark:bg-gray-950">
          {rows.map((row) => (
            <tr key={row.id}>
              <td className="px-2 py-1 text-gray-800 dark:text-gray-200">{row.label ?? t("tool_connection_id", { id: row.id })}</td>
              <td className="px-2 py-1 font-mono text-gray-600 dark:text-gray-300">{row.defaultDatabase ?? "—"}</td>
              <td className="whitespace-nowrap px-2 py-1"><AccessPill enabled={row.agenticAccessEnabled} label={row.agenticAccessEnabled ? t("agentic_enabled") : t("agentic_disabled")} /></td>
              <td className="whitespace-nowrap px-2 py-1"><AccessPill enabled={row.allowWrites} label={row.allowWrites ? t("allow_writes_enabled") : t("allow_writes_disabled")} /></td>
            </tr>
          ))}
        </tbody>
      </table>
    </TableShell>
  )
}

const listConnectionsToolCard: ToolCardRenderer = {
  toolName: "mysql_db_browser_list_connections",
  collapsedSummary,
  renderExpanded
}

export default listConnectionsToolCard
