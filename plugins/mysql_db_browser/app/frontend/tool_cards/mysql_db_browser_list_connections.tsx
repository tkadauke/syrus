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

  return `${rows.length} connection${rows.length === 1 ? "" : "s"}`
}

function renderExpanded(context: ToolCardContext) {
  const rows = connectionRows(context)
  if (!rows) return null
  if (rows.length === 0) return <EmptyState>No MySQL DB Browser connections configured.</EmptyState>

  return (
    <TableShell>
      <table className="w-full text-left text-xs">
        <thead className="bg-gray-50 text-2xs uppercase text-gray-500 dark:bg-gray-900 dark:text-gray-400">
          <tr>
            <th className="px-2 py-1 font-semibold" scope="col">
              Label
            </th>
            <th className="px-2 py-1 font-semibold" scope="col">
              Default database
            </th>
            <th className="px-2 py-1 font-semibold" scope="col">
              Agentic access
            </th>
            <th className="px-2 py-1 font-semibold" scope="col">
              Writes
            </th>
          </tr>
        </thead>
        <tbody className="divide-y divide-gray-100 bg-white dark:divide-gray-800 dark:bg-gray-950">
          {rows.map((row) => (
            <tr key={row.id}>
              <td className="px-2 py-1 text-gray-800 dark:text-gray-200">{row.label ?? `Connection #${row.id}`}</td>
              <td className="px-2 py-1 font-mono text-gray-600 dark:text-gray-300">{row.defaultDatabase ?? "—"}</td>
              <td className="whitespace-nowrap px-2 py-1">
                <AccessPill enabled={row.agenticAccessEnabled} label={row.agenticAccessEnabled ? "enabled" : "disabled"} />
              </td>
              <td className="whitespace-nowrap px-2 py-1">
                <AccessPill enabled={row.allowWrites} label={row.allowWrites ? "read-write" : "read-only"} />
              </td>
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
