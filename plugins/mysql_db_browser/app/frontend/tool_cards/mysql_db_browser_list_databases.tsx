import i18n from "i18next"
import { isPlainObject, type ToolCardContext, type ToolCardExample, type ToolCardRenderer } from "@app/pluginToolCards"
import { CardShell, CopyableValue, Disclosure, displayValue, EmptyState, FilterableList, InternalLink, Row, SectionLabel } from "@app/routes/chat/toolCardUi"
import { MysqlErrorNotice, parseConnection, parseDatabase, parseMysqlError, type MysqlDatabaseRow, type MysqlError } from "../mysqlToolCard"

// Plugin-owned tool card for mysql_db_browser_list_databases (the tool-card work).
type DatabasesCard = { available: true; connectionId: string | null; connectionLabel: string | null; generatedAt: string | null; databases: MysqlDatabaseRow[] }
type DatabasesErrorCard = { available: false; connectionId: string | null; connectionLabel: string | null; error: MysqlError | null }

function connectionLabel(context: ToolCardContext, connectionId: string | null) {
  if (!connectionId) return null
  const prior = context.priorResults?.mysql_db_browser_list_connections
  if (!isPlainObject(prior) || !Array.isArray(prior.mysql_connections)) return null
  for (const value of prior.mysql_connections) {
    const connection = parseConnection(value)
    if (connection?.id === connectionId) return connection.label
  }
  return null
}

function parseCard(context: ToolCardContext): DatabasesCard | DatabasesErrorCard | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed)) return null
  const connectionId = displayValue(context.input?.mysql_connection_id)
  const shared = { connectionId, connectionLabel: connectionLabel(context, connectionId) }
  if (parsed.available !== true) return { available: false, ...shared, error: parseMysqlError(parsed.error) }
  if (!Array.isArray(parsed.databases)) return null

  return {
    available: true,
    ...shared,
    generatedAt: displayValue(parsed.generated_at),
    databases: parsed.databases.flatMap((entry) => {
      const row = parseDatabase(entry)
      return row ? [row] : []
    })
  }
}

function collapsedSummary(context: ToolCardContext) {
  const card = parseCard(context)
  if (!card || !card.available) return null

  return t("tool_databases_count", { count: card.databases.length })
}

function t(key: string, options?: Record<string, unknown>) {
  return i18n.t(`mysql_db_browser:${key}`, options)
}

function connectionValue(card: DatabasesCard | DatabasesErrorCard) {
  if (!card.connectionId) return null
  return (
    <InternalLink href={`/db_browser?connection_id=${encodeURIComponent(card.connectionId)}`}>
      {card.connectionLabel
        ? t("tool_connection_label_with_id", { label: card.connectionLabel, id: card.connectionId })
        : t("tool_connection_id", { id: card.connectionId })}
    </InternalLink>
  )
}

function DatabaseRows({ rows }: { rows: MysqlDatabaseRow[] }) {
  return (
    <ul className="grid min-w-0 gap-2 sm:grid-cols-2">
      {rows.map((row) => (
        <li className="min-w-0 rounded border border-border p-2" key={row.name}>
          <CopyableValue value={row.name} />
          <dl className="mt-2 grid min-w-0 grid-cols-1 gap-1">
            <Row label={t("tool_character_set")} value={row.defaultCharacterSet ?? "—"} />
            <Row label={t("tool_collation")} value={row.defaultCollation ?? "—"} />
          </dl>
        </li>
      ))}
    </ul>
  )
}

function renderExpanded(context: ToolCardContext) {
  const card = parseCard(context)
  if (!card) return null
  const connection = connectionValue(card)
  if (!card.available) {
    return (
      <CardShell>
        {connection ? <Row label={t("tool_connection")} value={connection} /> : null}
        {card.error ? <MysqlErrorNotice error={card.error} /> : <EmptyState>{t("tool_unknown_error")}</EmptyState>}
      </CardShell>
    )
  }

  const applicationDatabases = card.databases.filter((row) => !row.systemSchema)
  const systemDatabases = card.databases.filter((row) => row.systemSchema)
  return (
    <CardShell>
      <div className="grid min-w-0 grid-cols-1 gap-2 sm:grid-cols-2">
        {connection ? <Row label={t("tool_connection")} value={connection} /> : null}
        <Row label={t("tool_generated_at")} value={card.generatedAt ?? "—"} />
      </div>
      {card.databases.length === 0 ? (
        <EmptyState>{t("tool_no_databases")}</EmptyState>
      ) : (
        <div className="min-w-0 space-y-2">
          <SectionLabel>{t("tool_database_list")}</SectionLabel>
          {applicationDatabases.length > 0 ? (
            <FilterableList
              emptyLabel={t("tool_no_matching_databases")}
              itemText={(row) => [row.name, row.defaultCharacterSet, row.defaultCollation].filter(Boolean).join(" ")}
              items={applicationDatabases}
              placeholder={t("tool_filter_databases")}
            >
              {(rows) => <DatabaseRows rows={rows} />}
            </FilterableList>
          ) : (
            <EmptyState>{t("tool_no_application_databases")}</EmptyState>
          )}
          {systemDatabases.length > 0 ? (
            <Disclosure label={t("tool_system_schemas_count", { count: systemDatabases.length })}>
              <DatabaseRows rows={systemDatabases} />
            </Disclosure>
          ) : null}
        </div>
      )}
    </CardShell>
  )
}

const listDatabasesToolCard: ToolCardRenderer = {
  toolName: "mysql_db_browser_list_databases",
  collapsedSummary,
  renderExpanded
}

export default listDatabasesToolCard

export const examples: ToolCardExample[] = [
  {
    id: "databases_with_system_schemas",
    label: "Application databases and system schemas",
    input: { mysql_connection_id: 7 },
    priorCalls: [{ toolName: "mysql_db_browser_list_connections", input: {}, parsedResult: { mysql_connections: [{ id: 7, label: "Production reporting" }] } }],
    parsedResult: {
      available: true,
      generated_at: "2026-10-23T10:00:00Z",
      databases: [
        { name: "analytics", system_schema: false, default_character_set: "utf8mb4", default_collation: "utf8mb4_0900_ai_ci" },
        { name: "information_schema", system_schema: true, default_character_set: "utf8mb3", default_collation: "utf8mb3_general_ci" }
      ]
    }
  },
  { id: "no_visible_databases", label: "No visible databases", input: { mysql_connection_id: 7 }, parsedResult: { available: true, databases: [] } },
  {
    id: "database_list_error",
    label: "Database listing error",
    input: { mysql_connection_id: 7 },
    parsedResult: {
      available: false,
      error: { class: "MysqlDbBrowser::AccessDenied", message: "Database metadata is unavailable.", hint: "Check this connection's grants." }
    }
  }
]
