import i18n from "i18next"
import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { CardShell, CopyableValue, EmptyState, InternalLink, Row, StatePill } from "@app/routes/chat/toolCardUi"
import { AccessPill, MysqlErrorNotice, parseConnection, parseMysqlError, type MysqlConnectionRow } from "../mysqlToolCard"

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
  if (!rows) {
    const parsed = context.parsedResult
    const error = isPlainObject(parsed) ? parseMysqlError(parsed.error ?? parsed) : null
    return error && (error.message || error.className) ? <MysqlErrorNotice error={error} /> : null
  }
  if (rows.length === 0) {
    return (
      <EmptyState>
        {t("tool_no_connections_agentic")} <InternalLink href="/db_browser">{t("tool_manage_connections")}</InternalLink>
      </EmptyState>
    )
  }

  return (
    <CardShell>
      <div className="flex justify-end">
        <InternalLink href="/db_browser">{t("tool_manage_connections")}</InternalLink>
      </div>
      <div className="grid gap-2 sm:grid-cols-2">
        {rows.map((row) => (
          <div className="min-w-0 space-y-2 rounded border border-gray-200 p-2 dark:border-gray-700" key={row.id}>
            <div className="flex min-w-0 flex-wrap items-center justify-between gap-2">
              <InternalLink className="min-w-0 break-words font-sans" href={`/db_browser?connection_id=${encodeURIComponent(row.id)}`}>
                {row.label ?? t("tool_connection_id", { id: row.id })}
              </InternalLink>
              {row.allowWrites ? <StatePill state={t("tool_write_access_warning")} tone="warning" /> : null}
            </div>
            <div className="grid min-w-0 gap-2 sm:grid-cols-2">
              <Row label={t("tool_connection_id_label")} value={<CopyableValue value={row.id} />} />
              <Row label={t("tool_default_database")} value={row.defaultDatabase ?? "—"} />
              <Row
                label={t("tool_agentic_access")}
                value={<AccessPill enabled={row.agenticAccessEnabled} label={row.agenticAccessEnabled ? t("agentic_enabled") : t("agentic_disabled")} />}
              />
              <Row
                label={t("tool_writes")}
                value={
                  <StatePill state={row.allowWrites ? t("allow_writes_enabled") : t("allow_writes_disabled")} tone={row.allowWrites ? "warning" : "neutral"} />
                }
              />
              <Row label={t("tool_created_at")} value={row.createdAt ?? "—"} />
              <Row label={t("tool_updated_at")} value={row.updatedAt ?? "—"} />
            </div>
          </div>
        ))}
      </div>
    </CardShell>
  )
}

const listConnectionsToolCard: ToolCardRenderer = {
  toolName: "mysql_db_browser_list_connections",
  collapsedSummary,
  renderExpanded
}

export default listConnectionsToolCard
