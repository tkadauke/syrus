import i18n from "i18next"
import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { MarkdownPreview } from "@app/routes/chat/toolCardMarkdown"
import { CardShell, CopyableValue, displayValue, EmptyState, FilterableList, Row, SectionLabel } from "@app/routes/chat/toolCardUi"
import { formatBytes } from "@app/lib/format"
import { MysqlErrorNotice, parseMysqlError, parseTableSummary, TruncatedNotice, type MysqlError, type MysqlTableRow } from "../mysqlToolCard"

// Plugin-owned tool card for mysql_db_browser_list_tables (the tool-card work).
type TablesCard = {
  available: true
  connectionId: string | null
  requestedDatabase: string | null
  database: string
  systemSchema: boolean
  generatedAt: string | null
  truncated: boolean
  tables: MysqlTableRow[]
}
type TablesErrorCard = { available: false; connectionId: string | null; requestedDatabase: string | null; error: MysqlError | null }

function parseCard(context: ToolCardContext): TablesCard | TablesErrorCard | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed)) return null
  const input = isPlainObject(context.input) ? context.input : {}
  const shared = {
    connectionId: displayValue(input.mysql_connection_id),
    requestedDatabase: displayValue(input.database)
  }
  if (parsed.available !== true) return { available: false, ...shared, error: parseMysqlError(parsed.error) }
  if (!Array.isArray(parsed.tables)) return null

  const database = displayValue(parsed.database)
  if (!database) return null

  return {
    available: true,
    ...shared,
    database,
    systemSchema: parsed.system_schema === true,
    generatedAt: displayValue(parsed.generated_at),
    truncated: parsed.truncated === true,
    tables: parsed.tables.flatMap((entry) => {
      const row = parseTableSummary(entry)
      return row ? [row] : []
    })
  }
}

function collapsedSummary(context: ToolCardContext) {
  const card = parseCard(context)
  if (!card || !card.available) return null

  return t("tool_tables_count", { count: card.tables.length, database: card.database })
}

function t(key: string, options?: Record<string, unknown>) {
  return i18n.t(`mysql_db_browser:${key}`, options)
}

function tableHref(card: TablesCard, table: string) {
  if (!card.connectionId) return null
  const params = new URLSearchParams({ connection_id: card.connectionId, database: card.requestedDatabase ?? card.database, table, tab: "structure" })
  return `/db_browser?${params.toString()}`
}

function TableRows({ card, tables }: { card: TablesCard; tables: MysqlTableRow[] }) {
  return (
    <ul className="space-y-2">
      {tables.map((row) => (
        <li className="min-w-0 rounded border border-border p-2" key={row.name}>
          <div className="flex min-w-0 flex-wrap items-center justify-between gap-2">
            <CopyableValue href={tableHref(card, row.name)} value={row.name} />
            <span className="text-2xs text-text-muted">{[row.type, row.engine].filter(Boolean).join(" · ") || "—"}</span>
          </div>
          <dl className="mt-2 grid min-w-0 grid-cols-1 gap-1 sm:grid-cols-2 lg:grid-cols-3">
            <Row label={t("tool_rows_approx")} value={row.approxRowCount?.toLocaleString() ?? "—"} />
            <Row label={t("tool_data_size")} value={formatBytes(row.dataLengthBytes)} />
            <Row label={t("tool_index_size")} value={formatBytes(row.indexLengthBytes)} />
            <Row label={t("tool_created_at")} value={row.createdAt ?? "—"} />
            <Row label={t("tool_updated_at")} value={row.updatedAt ?? "—"} />
          </dl>
          <div className="mt-2 min-w-0">
            <MarkdownPreview emptyState={t("tool_no_comment")} maxLines={4} text={row.comment} title={t("tool_comment")} />
          </div>
        </li>
      ))}
    </ul>
  )
}

function renderExpanded(context: ToolCardContext) {
  const card = parseCard(context)
  if (!card) return null
  if (!card.available) {
    return (
      <CardShell>
        {card.connectionId ? <Row copyable label={t("tool_connection")} value={t("tool_connection_id", { id: card.connectionId })} /> : null}
        {card.requestedDatabase ? <Row copyable label={t("tool_database")} value={card.requestedDatabase} /> : null}
        {card.error ? <MysqlErrorNotice error={card.error} /> : <EmptyState>{t("tool_unknown_error")}</EmptyState>}
      </CardShell>
    )
  }

  return (
    <CardShell>
      <div className="grid min-w-0 grid-cols-1 gap-2 sm:grid-cols-2">
        {card.connectionId ? <Row copyable label={t("tool_connection")} value={t("tool_connection_id", { id: card.connectionId })} /> : null}
        <Row copyable label={t("tool_database")} value={card.requestedDatabase ?? card.database} />
        {card.requestedDatabase && card.requestedDatabase !== card.database ? <Row copyable label={t("tool_result_database")} value={card.database} /> : null}
        <Row label={t("tool_system_schema")} value={card.systemSchema ? t("yes") : t("no")} />
        <Row label={t("tool_generated_at")} value={card.generatedAt ?? "—"} />
      </div>
      <div className="min-w-0">
        <SectionLabel>{t("tool_table_list")}</SectionLabel>
        {card.tables.length === 0 ? (
          <EmptyState>{t("tool_no_tables_in_database", { database: card.database })}</EmptyState>
        ) : (
          <FilterableList
            itemText={(row) => [row.name, row.type, row.engine, row.comment].filter(Boolean).join(" ")}
            items={card.tables}
            placeholder={t("tool_filter_tables")}
          >
            {(tables) => <TableRows card={card} tables={tables} />}
          </FilterableList>
        )}
      </div>
      {card.truncated ? <TruncatedNotice label={t("tool_table_list")} /> : null}
    </CardShell>
  )
}

const listTablesToolCard: ToolCardRenderer = {
  toolName: "mysql_db_browser_list_tables",
  collapsedSummary,
  renderExpanded
}

export default listTablesToolCard
