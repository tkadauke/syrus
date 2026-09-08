import type { ReactNode } from "react"
import { isPlainObject } from "@app/pluginToolCards"
import { displayValue, numberValue, StatePill } from "@app/routes/chat/toolCardUi"

// Shared presentation helpers for the mysql_db_browser plugin's chat tool
// cards (EPIC-293 / JOB-4226). mysql_db_browser_list_databases,
// mysql_db_browser_list_tables, mysql_db_browser_describe_table, and
// mysql_db_browser_execute_query all echo the same
// `{ class, message, hint? }` error shape for a failed section or statement
// (see plugins/mysql_db_browser/app/services/mysql_db_browser/{schema_inspector,query_executor}.rb),
// so this module parses and renders that subset once.
//
// Lives outside `tool_cards/` on purpose: core's pluginToolCards.tsx glob
// treats every non-test .tsx file under `tool_cards/` as a card module and
// would warn about the missing default export (same reason test_insights and
// design_docs keep their shared modules beside this one).
export type MysqlError = { className: string | null; message: string | null; hint: string | null }

export function parseMysqlError(value: unknown): MysqlError | null {
  if (!isPlainObject(value)) return null

  return {
    className: displayValue(value.class),
    message: displayValue(value.message),
    hint: displayValue(value.hint)
  }
}

export function MysqlErrorNotice({ error }: { error: MysqlError }) {
  return (
    <div className="rounded border border-red-200 bg-red-50 px-2 py-1 text-red-700 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
      <div className="font-mono">{error.message ?? error.className ?? "Unknown error"}</div>
      {error.hint ? <div className="mt-1 text-red-600 dark:text-red-400">{error.hint}</div> : null}
    </div>
  )
}

export function TruncatedNotice({ label }: { label: string }) {
  return <div className="text-2xs text-gray-500 dark:text-gray-400">{label} truncated -- narrow the query for a complete view.</div>
}

export function AccessPill({ enabled, label }: { enabled: boolean; label: string }) {
  return <StatePill state={label} tone={enabled ? "success" : "neutral"} />
}

export function TableShell({ children }: { children: ReactNode }) {
  return <div className="mt-1 overflow-x-auto rounded border border-gray-200 dark:border-gray-700">{children}</div>
}

export type MysqlConnectionRow = {
  id: string
  label: string | null
  defaultDatabase: string | null
  agenticAccessEnabled: boolean
  allowWrites: boolean
}

export function parseConnection(value: unknown): MysqlConnectionRow | null {
  if (!isPlainObject(value)) return null
  const id = displayValue(value.id)
  if (!id) return null

  return {
    id,
    label: displayValue(value.label),
    defaultDatabase: displayValue(value.default_database),
    agenticAccessEnabled: value.agentic_access_enabled === true,
    allowWrites: value.allow_writes === true
  }
}

export type MysqlDatabaseRow = {
  name: string
  systemSchema: boolean
  defaultCharacterSet: string | null
  defaultCollation: string | null
}

export function parseDatabase(value: unknown): MysqlDatabaseRow | null {
  if (!isPlainObject(value)) return null
  const name = displayValue(value.name)
  if (!name) return null

  return {
    name,
    systemSchema: value.system_schema === true,
    defaultCharacterSet: displayValue(value.default_character_set),
    defaultCollation: displayValue(value.default_collation)
  }
}

export type MysqlTableRow = {
  name: string
  type: string | null
  engine: string | null
  approxRowCount: number | null
  dataLengthBytes: number | null
  indexLengthBytes: number | null
  comment: string | null
}

export function parseTableSummary(value: unknown): MysqlTableRow | null {
  if (!isPlainObject(value)) return null
  const name = displayValue(value.name)
  if (!name) return null

  return {
    name,
    type: displayValue(value.type),
    engine: displayValue(value.engine),
    approxRowCount: numberValue(value.approximate_row_count),
    dataLengthBytes: numberValue(value.data_length_bytes),
    indexLengthBytes: numberValue(value.index_length_bytes),
    comment: displayValue(value.comment)
  }
}

export type MysqlColumnRow = {
  name: string
  columnType: string | null
  nullable: boolean
  key: string | null
  default: string | null
  extra: string | null
}

export function parseColumn(value: unknown): MysqlColumnRow | null {
  if (!isPlainObject(value)) return null
  const name = displayValue(value.name)
  if (!name) return null

  return {
    name,
    columnType: displayValue(value.column_type),
    nullable: value.nullable === true,
    key: displayValue(value.key),
    default: displayValue(value.default),
    extra: displayValue(value.extra)
  }
}

export type MysqlIndexRow = { name: string | null; unique: boolean; type: string | null; columns: string[] }

export function parseIndex(value: unknown): MysqlIndexRow | null {
  if (!isPlainObject(value)) return null

  return {
    name: displayValue(value.name),
    unique: value.unique === true,
    type: displayValue(value.type),
    columns: Array.isArray(value.columns) ? value.columns.filter((c): c is string => typeof c === "string") : []
  }
}

export type MysqlForeignKeyRow = {
  key: string
  direction: string | null
  fromTable: string | null
  fromColumn: string | null
  toTable: string | null
  toColumn: string | null
}

export function parseForeignKey(value: unknown, index: number): MysqlForeignKeyRow | null {
  if (!isPlainObject(value)) return null

  return {
    key: displayValue(value.constraint_name) ?? String(index),
    direction: displayValue(value.direction),
    fromTable: displayValue(value.from_table),
    fromColumn: displayValue(value.from_column),
    toTable: displayValue(value.to_table),
    toColumn: displayValue(value.to_column)
  }
}

// describe_table's `info` section is a single object, not a row list --
// separate shape from the columns/indexes/foreign_keys sections below.
export type MysqlTableInfo = {
  type: string | null
  engine: string | null
  approxRowCount: number | null
  dataLengthBytes: number | null
  indexLengthBytes: number | null
  autoIncrement: number | null
  collation: string | null
  comment: string | null
}

export type MysqlInfoSection = { available: true; info: MysqlTableInfo } | { available: false; error: MysqlError | null }

export function parseInfoSection(value: unknown): MysqlInfoSection {
  if (!isPlainObject(value)) return { available: false, error: null }
  if (value.available !== true) return { available: false, error: parseMysqlError(value.error) }

  return {
    available: true,
    info: {
      type: displayValue(value.type),
      engine: displayValue(value.engine),
      approxRowCount: numberValue(value.approximate_row_count),
      dataLengthBytes: numberValue(value.data_length_bytes),
      indexLengthBytes: numberValue(value.index_length_bytes),
      autoIncrement: numberValue(value.auto_increment),
      collation: displayValue(value.collation),
      comment: displayValue(value.comment)
    }
  }
}

export function formatMs(value: number | null | undefined): string {
  if (value == null) return "—"
  if (value < 1000) return `${Math.round(value)}ms`
  return `${(value / 1000).toFixed(2)}s`
}

// A schema section (columns/indexes/foreign_keys/info) is independently
// `{ available: true, ... }` or `{ available: false, error }` -- a partial
// GRANT failure on one section shouldn't hide the sections that did load.
export type MysqlSection<T> = { available: true; truncated: boolean; rows: T[] } | { available: false; error: MysqlError | null }

export function parseSection<T>(value: unknown, parseRow: (row: unknown, index: number) => T | null): MysqlSection<T> {
  if (!isPlainObject(value)) return { available: false, error: null }
  if (value.available !== true) return { available: false, error: parseMysqlError(value.error) }

  const rows = Array.isArray(value.rows)
    ? value.rows.flatMap((row, index) => { const parsed = parseRow(row, index); return parsed ? [parsed] : [] })
    : []

  return { available: true, truncated: value.truncated === true, rows }
}
