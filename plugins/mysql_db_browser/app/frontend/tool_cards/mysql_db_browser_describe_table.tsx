import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { CardShell, displayValue, Row, SectionLabel } from "@app/routes/chat/toolCardUi"
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

// Plugin-owned tool card for mysql_db_browser_describe_table (EPIC-293).
// Each of the four sections (info/columns/indexes/foreign_keys) can
// independently be `{available: false, error}` on a partial GRANT failure
// (see MysqlDbBrowser::SchemaInspector#safe_section) -- render whichever
// sections did load instead of failing the whole card.
type DescribeTableCard = {
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

  const database = displayValue(parsed.database)
  const table = displayValue(parsed.table)
  if (!database || !table) return null

  return {
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

  const columnCount = card.columns.available ? `${card.columns.rows.length} columns` : "columns unavailable"
  return `${card.database}.${card.table} (${columnCount})`
}

function InfoSection({ section }: { section: MysqlInfoSection }) {
  if (!section.available) return section.error ? <MysqlErrorNotice error={section.error} /> : null

  return (
    <dl className="grid gap-1 sm:grid-cols-2">
      {section.info.type ? <Row label="Type" value={section.info.type} /> : null}
      {section.info.engine ? <Row label="Engine" value={section.info.engine} /> : null}
      {section.info.approxRowCount != null ? <Row label="Rows (approx)" value={section.info.approxRowCount.toLocaleString()} /> : null}
      <Row label="Data size" value={formatBytes(section.info.dataLengthBytes)} />
      <Row label="Index size" value={formatBytes(section.info.indexLengthBytes)} />
      {section.info.autoIncrement != null ? <Row label="Auto increment" value={String(section.info.autoIncrement)} /> : null}
      {section.info.collation ? <Row label="Collation" value={section.info.collation} /> : null}
    </dl>
  )
}

function ColumnsSection({ section }: { section: MysqlSection<MysqlColumnRow> }) {
  if (!section.available) return section.error ? <MysqlErrorNotice error={section.error} /> : null
  if (section.rows.length === 0) return <div className="text-gray-500 dark:text-gray-400">No columns.</div>

  return (
    <div className="space-y-1">
      <TableShell>
        <table className="w-full text-left text-xs">
          <thead className="bg-gray-50 text-2xs uppercase text-gray-500 dark:bg-gray-900 dark:text-gray-400">
            <tr>
              <th className="px-2 py-1 font-semibold" scope="col">Column</th>
              <th className="px-2 py-1 font-semibold" scope="col">Type</th>
              <th className="px-2 py-1 font-semibold" scope="col">Nullable</th>
              <th className="px-2 py-1 font-semibold" scope="col">Key</th>
              <th className="px-2 py-1 font-semibold" scope="col">Default</th>
              <th className="px-2 py-1 font-semibold" scope="col">Extra</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-gray-100 bg-white dark:divide-gray-800 dark:bg-gray-950">
            {section.rows.map((column) => (
              <tr key={column.name}>
                <td className="px-2 py-1 font-mono text-gray-800 dark:text-gray-200">{column.name}</td>
                <td className="px-2 py-1 font-mono text-gray-600 dark:text-gray-300">{column.columnType ?? "—"}</td>
                <td className="whitespace-nowrap px-2 py-1 text-gray-600 dark:text-gray-300">{column.nullable ? "yes" : "no"}</td>
                <td className="px-2 py-1 text-gray-600 dark:text-gray-300">{column.key ?? "—"}</td>
                <td className="px-2 py-1 font-mono text-gray-600 dark:text-gray-300">{column.default ?? "—"}</td>
                <td className="px-2 py-1 text-gray-600 dark:text-gray-300">{column.extra ?? "—"}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </TableShell>
      {section.truncated ? <TruncatedNotice label="Column list" /> : null}
    </div>
  )
}

function IndexesSection({ section }: { section: MysqlSection<MysqlIndexRow> }) {
  if (!section.available) return section.error ? <MysqlErrorNotice error={section.error} /> : null
  if (section.rows.length === 0) return <div className="text-gray-500 dark:text-gray-400">No indexes.</div>

  return (
    <ul className="space-y-1">
      {section.rows.map((index, i) => (
        <li className="font-mono text-gray-700 dark:text-gray-300" key={index.name ?? i}>
          {index.name ?? "(unnamed)"} {index.unique ? "unique" : ""} {index.type ? `[${index.type}]` : ""} ({index.columns.join(", ")})
        </li>
      ))}
    </ul>
  )
}

function ForeignKeysSection({ section }: { section: MysqlSection<MysqlForeignKeyRow> }) {
  if (!section.available) return section.error ? <MysqlErrorNotice error={section.error} /> : null
  if (section.rows.length === 0) return <div className="text-gray-500 dark:text-gray-400">No foreign keys.</div>

  return (
    <ul className="space-y-1">
      {section.rows.map((fk) => (
        <li className="font-mono text-gray-700 dark:text-gray-300" key={fk.key}>
          [{fk.direction ?? "?"}] {fk.fromTable}.{fk.fromColumn} → {fk.toTable}.{fk.toColumn}
        </li>
      ))}
    </ul>
  )
}

function renderExpanded(context: ToolCardContext) {
  const card = parseCard(context)
  if (!card) return null

  return (
    <CardShell>
      <div className="font-mono font-medium text-gray-800 dark:text-gray-100">{card.database}.{card.table}</div>
      <div>
        <SectionLabel>Info</SectionLabel>
        <InfoSection section={card.info} />
      </div>
      <div>
        <SectionLabel>Columns</SectionLabel>
        <ColumnsSection section={card.columns} />
      </div>
      <div>
        <SectionLabel>Indexes</SectionLabel>
        <IndexesSection section={card.indexes} />
      </div>
      <div>
        <SectionLabel>Foreign keys</SectionLabel>
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
