import { getJson } from "@app/api/client"

export type MysqlDatabaseRow = {
  name: string
  system_schema: boolean
  default_character_set: string | null
  default_collation: string | null
}

export type MysqlDatabasesResponse = {
  available: boolean
  generated_at: string
  databases: MysqlDatabaseRow[]
}

export type MysqlTableSummary = {
  name: string
  type: string | null
  engine: string | null
  approximate_row_count: number | null
  data_length_bytes: number | null
  index_length_bytes: number | null
  created_at: string | null
  updated_at: string | null
  comment: string | null
}

export type MysqlTablesSection =
  | { available: true; generated_at: string; database: string; system_schema: boolean; truncated: boolean; tables: MysqlTableSummary[] }
  | { available: false; error: { class: string; message: string; hint?: string } }

export type MysqlTableInfo = {
  type: string | null
  engine: string | null
  approximate_row_count: number | null
  data_length_bytes: number | null
  index_length_bytes: number | null
  auto_increment: number | null
  created_at: string | null
  updated_at: string | null
  collation: string | null
  comment: string | null
}

export type MysqlColumn = {
  name: string
  column_type: string
  data_type: string
  nullable: boolean
  key: string | null
  default: string | null
  extra: string | null
  character_max_length: number | null
  numeric_precision: number | null
  numeric_scale: number | null
  comment: string | null
}

export type MysqlIndex = {
  name: string
  unique: boolean
  type: string | null
  columns: string[]
}

export type MysqlSection<TRow> =
  | { available: true; truncated: boolean; rows: TRow[] }
  | { available: false; error: { class: string; message: string; hint?: string } }

export type MysqlTableDetailResponse = {
  database: string
  table: string
  system_schema: boolean
  generated_at: string
  info: { available: true } & MysqlTableInfo | { available: false; error: { class: string; message: string; hint?: string } }
  columns: MysqlSection<MysqlColumn>
  indexes: MysqlSection<MysqlIndex>
}

export function fetchMysqlDatabases(connectionId: number) {
  return getJson<MysqlDatabasesResponse>(`/api/v1/app/admin/mysql_connections/${connectionId}/schema`)
}

export function fetchMysqlTables(connectionId: number, database: string) {
  return getJson<MysqlTablesSection>(`/api/v1/app/admin/mysql_connections/${connectionId}/schema/${encodeURIComponent(database)}/tables`)
}

export function fetchMysqlTableDetail(connectionId: number, database: string, table: string) {
  return getJson<MysqlTableDetailResponse>(
    `/api/v1/app/admin/mysql_connections/${connectionId}/schema/${encodeURIComponent(database)}/tables/${encodeURIComponent(table)}`
  )
}
