import i18n from "i18next"
import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { MarkdownPreview } from "@app/routes/chat/toolCardMarkdown"
import { CardShell, CopyableValue, displayValue, Row, SectionLabel } from "@app/routes/chat/toolCardUi"
import { formatBytes } from "@app/lib/format"
import {
  MysqlErrorNotice,
  parseColumn,
  parseForeignKey,
  parseIndex,
  parseInfoSection,
  parseSection,
  TableShell,
  TruncatedNotice,
  type MysqlColumnRow,
  type MysqlForeignKeyRow,
  type MysqlIndexRow,
  type MysqlInfoSection,
  type MysqlSection
} from "../mysqlToolCard"

// Plugin-owned tool card for mysql_db_browser_describe_table (the tool-card work).
// Each of the four sections (info/columns/indexes/foreign_keys) can
// independently be `{available: false, error}` on a partial GRANT failure
// (see MysqlDbBrowser::SchemaInspector#safe_section) -- render whichever
// sections did load instead of failing the whole card.
type DescribeTableCard = {
  connectionId: string | null
  requestedDatabase: string | null
  requestedTable: string | null
  database: string
  table: string
  info: MysqlInfoSection
  columns: MysqlSection<MysqlColumnRow>
  indexes: MysqlSection<MysqlIndexRow>
  foreignKeys: MysqlSection<MysqlForeignKeyRow>
}

function parseCard(context: ToolCardContext): DescribeTableCard | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed)) return null
  const input = isPlainObject(context.input) ? context.input : {}

  const database = displayValue(parsed.database)
  const table = displayValue(parsed.table)
  if (!database || !table) return null

  return {
    connectionId: displayValue(input.mysql_connection_id),
    requestedDatabase: displayValue(input.database),
    requestedTable: displayValue(input.table),
    database,
    table,
    info: parseInfoSection(parsed.info),
    columns: parseSection(parsed.columns, parseColumn),
    indexes: parseSection(parsed.indexes, parseIndex),
    foreignKeys: parseSection(parsed.foreign_keys, parseForeignKey)
  }
}

function collapsedSummary(context: ToolCardContext) {
  const card = parseCard(context)
  if (!card) return null

  const columnCount = card.columns.available ? t("tool_columns_count", { count: card.columns.rows.length }) : t("tool_columns_unavailable")
  return `${card.database}.${card.table} (${columnCount})`
}

function t(key: string, options?: Record<string, unknown>) {
  return i18n.t(`mysql_db_browser:${key}`, options)
}

function InfoSection({ section }: { section: MysqlInfoSection }) {
  if (!section.available) return section.error ? <MysqlErrorNotice error={section.error} /> : null

  return (
    <dl className="grid gap-1 sm:grid-cols-2">
      <Row label={t("tool_type")} value={section.info.type ?? "—"} />
      <Row label={t("tool_engine")} value={section.info.engine ?? "—"} />
      <Row label={t("tool_rows_approx")} value={section.info.approxRowCount?.toLocaleString() ?? "—"} />
      <Row label={t("tool_data_size")} value={formatBytes(section.info.dataLengthBytes)} />
      <Row label={t("tool_index_size")} value={formatBytes(section.info.indexLengthBytes)} />
      <Row label={t("tool_auto_increment")} value={section.info.autoIncrement != null ? String(section.info.autoIncrement) : "—"} />
      <Row label={t("tool_collation")} value={section.info.collation ?? "—"} />
      <Row label={t("tool_created_at")} value={section.info.createdAt ?? "—"} />
      <Row label={t("tool_updated_at")} value={section.info.updatedAt ?? "—"} />
      <div className="min-w-0 sm:col-span-2">
        <MarkdownPreview emptyState={t("tool_no_comment")} maxLines={4} text={section.info.comment} title={t("tool_comment")} />
      </div>
    </dl>
  )
}

function ColumnsSection({ section }: { section: MysqlSection<MysqlColumnRow> }) {
  if (!section.available) return section.error ? <MysqlErrorNotice error={section.error} /> : null
  if (section.rows.length === 0)
    return (
      <div className="space-y-1">
        <div className="text-gray-500 dark:text-gray-400">{t("tool_no_columns")}</div>
        {section.truncated ? <TruncatedNotice label={t("tool_column_list")} /> : null}
      </div>
    )

  return (
    <div className="space-y-1">
      <TableShell>
        <table className="block w-full text-left text-xs sm:table">
          <thead className="hidden bg-gray-50 text-2xs uppercase text-gray-500 dark:bg-gray-900 dark:text-gray-400 sm:table-header-group">
            <tr>
              <th className="px-2 py-1 font-semibold" scope="col">
                {t("tool_column")}
              </th>
              <th className="px-2 py-1 font-semibold" scope="col">
                {t("tool_type")}
              </th>
              <th className="px-2 py-1 font-semibold" scope="col">
                {t("tool_data_type")}
              </th>
              <th className="px-2 py-1 font-semibold" scope="col">
                {t("tool_nullable")}
              </th>
              <th className="px-2 py-1 font-semibold" scope="col">
                {t("tool_key")}
              </th>
              <th className="px-2 py-1 font-semibold" scope="col">
                {t("tool_default")}
              </th>
              <th className="px-2 py-1 font-semibold" scope="col">
                {t("tool_extra")}
              </th>
              <th className="px-2 py-1 font-semibold" scope="col">
                {t("tool_character_max_length")}
              </th>
              <th className="px-2 py-1 font-semibold" scope="col">
                {t("tool_numeric_precision")}
              </th>
              <th className="px-2 py-1 font-semibold" scope="col">
                {t("tool_numeric_scale")}
              </th>
              <th className="px-2 py-1 font-semibold" scope="col">
                {t("tool_comment")}
              </th>
            </tr>
          </thead>
          <tbody className="block space-y-2 bg-white p-2 dark:bg-gray-950 sm:table-row-group sm:space-y-0 sm:p-0">
            {section.rows.map((column) => (
              <tr className="block rounded border border-border p-2 sm:table-row sm:rounded-none sm:border-0 sm:p-0" key={column.name}>
                <ColumnCell label={t("tool_column")} value={column.name} />
                <ColumnCell label={t("tool_type")} value={column.columnType} />
                <ColumnCell label={t("tool_data_type")} value={column.dataType} />
                <ColumnCell label={t("tool_nullable")} value={column.nullable ? t("yes") : t("no")} />
                <ColumnCell label={t("tool_key")} value={column.key} />
                <ColumnCell label={t("tool_default")} value={column.default} />
                <ColumnCell label={t("tool_extra")} value={column.extra} />
                <ColumnCell label={t("tool_character_max_length")} value={column.characterMaxLength} />
                <ColumnCell label={t("tool_numeric_precision")} value={column.numericPrecision} />
                <ColumnCell label={t("tool_numeric_scale")} value={column.numericScale} />
                <ColumnCell label={t("tool_comment")} value={column.comment} />
              </tr>
            ))}
          </tbody>
        </table>
      </TableShell>
      {section.truncated ? <TruncatedNotice label={t("tool_column_list")} /> : null}
    </div>
  )
}

function ColumnCell({ label, value }: { label: string; value: string | number | null }) {
  return (
    <td className="grid min-w-0 grid-cols-[minmax(6rem,0.4fr)_minmax(0,1fr)] gap-2 px-2 py-1 font-mono text-gray-600 dark:text-gray-300 sm:table-cell sm:min-w-32">
      <span className="break-words text-2xs font-semibold text-text-muted sm:hidden">{label}</span>
      <span className="min-w-0 break-words">{value ?? "—"}</span>
    </td>
  )
}

function IndexesSection({ section }: { section: MysqlSection<MysqlIndexRow> }) {
  if (!section.available) return section.error ? <MysqlErrorNotice error={section.error} /> : null
  if (section.rows.length === 0)
    return (
      <div className="space-y-1">
        <div className="text-gray-500 dark:text-gray-400">{t("tool_no_indexes")}</div>
        {section.truncated ? <TruncatedNotice label={t("tool_index_list")} /> : null}
      </div>
    )

  return (
    <div className="space-y-1">
      <ul className="space-y-1">
        {section.rows.map((index, i) => (
          <li className="break-words font-mono text-gray-700 dark:text-gray-300" key={index.name ?? i}>
            {index.name ?? "(unnamed)"} {index.unique ? "unique" : ""} {index.type ? `[${index.type}]` : ""} ({index.columns.join(", ")})
          </li>
        ))}
      </ul>
      {section.truncated ? <TruncatedNotice label={t("tool_index_list")} /> : null}
    </div>
  )
}

function ForeignKeysSection({ section }: { section: MysqlSection<MysqlForeignKeyRow> }) {
  if (!section.available) return section.error ? <MysqlErrorNotice error={section.error} /> : null
  if (section.rows.length === 0)
    return (
      <div className="space-y-1">
        <div className="text-gray-500 dark:text-gray-400">{t("tool_no_foreign_keys")}</div>
        {section.truncated ? <TruncatedNotice label={t("tool_foreign_key_list")} /> : null}
      </div>
    )

  return (
    <div className="space-y-1">
      <ul className="space-y-2">
        {section.rows.map((fk) => (
          <li className="min-w-0 rounded border border-border p-2 text-xs text-gray-700 dark:text-gray-300" key={fk.key}>
            <div className="break-words font-mono font-semibold">
              {fk.constraintName ?? "—"} <span className="text-text-muted">[{fk.direction ?? "?"}]</span>
            </div>
            <div className="mt-1 flex min-w-0 flex-wrap items-center gap-1 font-mono">
              {fk.fromTable ? <CopyableValue href="/db_browser" value={fk.fromTable} /> : "?"}
              <span>.{fk.fromColumn ?? "?"}</span>
              <span aria-hidden>→</span>
              {fk.toTable ? <CopyableValue href="/db_browser" value={fk.toTable} /> : "?"}
              <span>.{fk.toColumn ?? "?"}</span>
            </div>
          </li>
        ))}
      </ul>
      {section.truncated ? <TruncatedNotice label={t("tool_foreign_key_list")} /> : null}
    </div>
  )
}

function renderExpanded(context: ToolCardContext) {
  const card = parseCard(context)
  if (!card) return null

  return (
    <CardShell>
      <div className="font-mono font-medium text-gray-800 dark:text-gray-100">
        {card.database}.{card.table}
      </div>
      <div className="grid min-w-0 grid-cols-1 gap-2 sm:grid-cols-3">
        {card.connectionId ? <Row copyable label={t("tool_connection")} value={t("tool_connection_id", { id: card.connectionId })} /> : null}
        <Row copyable label={t("tool_database")} value={card.requestedDatabase ?? card.database} />
        <Row copyable label={t("tool_table")} value={card.requestedTable ?? card.table} />
      </div>
      <div>
        <SectionLabel>{t("tool_info")}</SectionLabel>
        <InfoSection section={card.info} />
      </div>
      <div>
        <SectionLabel>{t("tool_columns")}</SectionLabel>
        <ColumnsSection section={card.columns} />
      </div>
      <div>
        <SectionLabel>{t("tool_indexes")}</SectionLabel>
        <IndexesSection section={card.indexes} />
      </div>
      <div>
        <SectionLabel>{t("tool_foreign_keys")}</SectionLabel>
        <ForeignKeysSection section={card.foreignKeys} />
      </div>
    </CardShell>
  )
}

const describeTableToolCard: ToolCardRenderer = {
  toolName: "mysql_db_browser_describe_table",
  collapsedSummary,
  renderExpanded
}

export default describeTableToolCard
