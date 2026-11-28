import { getJson, postJson } from "@app/api/client"

export type MysqlConnectionSummary = {
  threads_connected: number | null
  threads_running: number | null
  max_used_connections: number | null
  max_connections: number | null
  sleeping_connections: number
  aborted_connects: number | null
  max_connection_errors: number | null
  wait_timeout: number | null
  interactive_timeout: number | null
}

export type MysqlProcess = {
  id: number
  user: string | null
  host: string | null
  database: string | null
  command: string | null
  time_seconds: number
  state: string | null
  info: string | null
}

export type MysqlStatementDigest = {
  schema_name: string | null
  digest_text: string | null
  count: number
  total_seconds: number | null
  avg_seconds: number | null
  max_seconds: number | null
  rows_sent: number
  rows_examined: number
  first_seen: string | null
  last_seen: string | null
}

export type MysqlSlowSqlEvent = {
  occurred_at: string | null
  duration_ms: number | null
  name?: string | null
  phase?: string | null
  sql?: string | null
  fingerprint?: string | null
  controller?: string | null
  action?: string | null
  job_class?: string | null
}

export type MysqlUnavailableSection = {
  available: false
  error?: {
    class?: string
    message: string
    hint?: string
    setup_sql?: string[]
  }
}

export type MysqlSnapshot = {
  available: true
  generated_at: string
  adapter: string
  database: string
  connection_summary: MysqlConnectionSummary
  variables: Record<string, string | number>
  status: Record<string, string | number>
  process_list: MysqlProcess[]
  statement_digests:
    | MysqlUnavailableSection
    | {
        available: true
        rows: MysqlStatementDigest[]
      }
  slow_sql_events: {
    available: boolean
    rows: MysqlSlowSqlEvent[]
    error?: {
      class?: string
      message: string
      hint?: string
      setup_sql?: string[]
    }
  }
}

export type MysqlKillQueryResult = {
  killed: boolean
  thread_id: number
  generated_at: string
  error?: {
    class: string
    message: string
  }
}

export function fetchAdminMysql(limit = 50, sections = "live", includeIdle = false) {
  const params = new URLSearchParams({
    limit: String(limit),
    sections,
    include_idle: String(includeIdle)
  })
  return getJson<Partial<MysqlSnapshot> & Pick<MysqlSnapshot, "available" | "generated_at">>(`/api/v1/app/admin/mysql?${params.toString()}`)
}

export function killMysqlQuery(threadId: number) {
  return postJson<MysqlKillQueryResult>("/api/v1/app/admin/mysql/kill_query", { thread_id: threadId })
}
