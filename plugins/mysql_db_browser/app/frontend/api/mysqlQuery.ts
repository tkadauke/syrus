import { getJson, postJson } from "@app/api/client"
import type { FilterSchemaField } from "@app/components/FilterBar"

export type MysqlQueryErrorPayload = {
  class: string
  message: string
  hint?: string
}

export type MysqlQueryResult = {
  available: boolean
  statement: string
  read_only: boolean
  columns: string[]
  rows: Array<Record<string, unknown>>
  row_count: number
  truncated: boolean
  duration_ms: number
  generated_at: string
  affected_rows?: number
  error?: MysqlQueryErrorPayload
}

export type MysqlContentResult = MysqlQueryResult & {
  filter_schema: FilterSchemaField[]
  filter: Record<string, unknown> | null
  page: number
  per_page: number
  has_more: boolean
}

export function executeMysqlQuery(connectionId: number, sql: string) {
  return postJson<MysqlQueryResult>(`/api/v1/app/admin/mysql_connections/${connectionId}/query`, { mysql_query: { sql } })
}

export function fetchMysqlTableContent(
  connectionId: number,
  database: string,
  table: string,
  params: { q?: string; sort_by?: string; sort_dir?: "asc" | "desc"; page?: number; per_page?: number }
) {
  const search = new URLSearchParams()
  if (params.q) search.set("q", params.q)
  if (params.sort_by) search.set("sort_by", params.sort_by)
  if (params.sort_dir) search.set("sort_dir", params.sort_dir)
  if (params.page) search.set("page", String(params.page))
  if (params.per_page) search.set("per_page", String(params.per_page))

  const query = search.toString()
  const path = `/api/v1/app/admin/mysql_connections/${connectionId}/schema/${encodeURIComponent(database)}/tables/${encodeURIComponent(table)}/content`
  return getJson<MysqlContentResult>(query ? `${path}?${query}` : path)
}

// Query builder spec - mirrors MysqlDbBrowser::QueryBuilderCompiler's spec
// shape server-side. Every column reference (columns, aggregations[].column,
// group_by, join.from_column/to_column, sort.column) is a "table.column"
// qualified string, resolved and validated against the real schema on the
// server - the frontend never needs its own copy of that validation.
export type MysqlBuilderAggregation = {
  function: "count" | "sum" | "avg" | "min" | "max"
  column: string
  alias?: string
}

export type MysqlBuilderJoin = {
  table: string
  type: "inner" | "left"
  from_column: string
  to_column: string
}

export type MysqlBuilderSort = {
  column: string
  direction: "asc" | "desc"
}

export type MysqlQueryBuilderSpec = {
  table: string
  columns?: string[]
  aggregations?: MysqlBuilderAggregation[]
  group_by?: string[]
  join?: MysqlBuilderJoin
  sort?: MysqlBuilderSort
  limit?: number
}

export function fetchMysqlQueryBuilderResult(
  connectionId: number,
  database: string,
  spec: MysqlQueryBuilderSpec,
  params: { q?: string } = {}
) {
  const search = new URLSearchParams()
  search.set("spec", JSON.stringify(spec))
  if (params.q) search.set("q", params.q)

  const path = `/api/v1/app/admin/mysql_connections/${connectionId}/schema/${encodeURIComponent(database)}/query_builder`
  return getJson<MysqlContentResult>(`${path}?${search.toString()}`)
}
