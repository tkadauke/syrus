import { getJson, postJson } from "@app/api/client"

export type PerformanceThresholds = {
  slow_request_ms: number
  slow_sql_ms: number
  slow_phase_ms: number
  top_sql_fingerprint_limit: number
  max_sql_fingerprints_per_request: number
}

export type PerformanceStorage = {
  kind: string
  cache_key?: string
  max_events: number
  expires_in_seconds: number
  buffered?: number
  dropped?: number
}

export type SlowRequestSummary = {
  method: string | null
  path: string | null
  controller: string | null
  action: string | null
  count: number
  total_duration_ms: number
  average_duration_ms: number | null
  max_duration_ms: number | null
  average_sql_count: number | null
  average_sql_duration_ms: number | null
  last_seen_at: string | null
}

export type SlowPhaseSummary = {
  phase: string
  count: number
  total_duration_ms: number
  average_duration_ms: number | null
  max_duration_ms: number | null
  last_seen_at: string | null
  recent_metadata?: Record<string, unknown> | null
}

export type BrowserTraceSummary = {
  name: string
  path: string | null
  count: number
  total_duration_ms: number
  average_duration_ms: number | null
  max_duration_ms: number | null
  average_api_duration_ms: number | null
  max_api_duration_ms: number | null
  recent_api_request_ids: string[]
  last_seen_at: string | null
  recent_metadata?: Record<string, unknown> | null
}

export type SqlFingerprintSummary = {
  fingerprint: string
  sample_sql?: string | null
  name?: string | null
  count: number
  total_duration_ms: number
  average_duration_ms: number | null
  max_duration_ms: number | null
}

export type PerformanceComparison = {
  key: string
  label: string
  current_average_duration_ms: number | null
  baseline_average_duration_ms: number | null
  delta_average_duration_ms: number | null
  delta_percent: number | null
  current_count: number
  baseline_count: number | null
  status: "regressed" | "improved" | "new" | "unchanged"
}

export type PerformanceEvent = {
  event: string
  occurred_at?: string | null
  app_revision?: string | null
  duration_ms?: number | null
  method?: string | null
  path?: string | null
  controller?: string | null
  action?: string | null
  phase?: string | null
  name?: string | null
  sql?: string | null
  fingerprint?: string | null
  sql_count?: number | null
  sql_duration_ms?: number | null
  slow_sql_count?: number | null
  status?: number | null
  metadata?: Record<string, unknown> | null
  trace_id?: string | null
  visibility_state?: string | null
  api_requests?: Array<{
    name?: string | null
    path?: string | null
    request_id?: string | null
    duration_ms?: number | null
    status?: number | null
  }> | null
}

export type AdminPerformancePayload = {
  enabled: boolean
  current_revision: string
  revision_scope: "current" | "all"
  thresholds: PerformanceThresholds
  storage: PerformanceStorage
  baseline: {
    revision: string | null
    comparisons: {
      slow_requests: PerformanceComparison[]
      slow_phases: PerformanceComparison[]
      browser_traces: PerformanceComparison[]
      sql_fingerprints: PerformanceComparison[]
    }
  }
  summaries: {
    slow_requests: SlowRequestSummary[]
    slow_phases: SlowPhaseSummary[]
    browser_traces: BrowserTraceSummary[]
    sql_fingerprints: SqlFingerprintSummary[]
  }
  events: PerformanceEvent[]
}

export type SqlExplainResult = {
  adapter: string
  mode: "explain" | "analyze"
  normalized_sql: string
  placeholder_substituted: boolean
  timeout_ms: number | null
  rows: Array<Record<string, unknown>>
  json_plan: Record<string, unknown> | null
  warnings: string[]
}

export function fetchAdminPerformance(limit = 200, revisionScope: "current" | "all" = "current") {
  const params = new URLSearchParams({ limit: String(limit), revision_scope: revisionScope })
  return getJson<AdminPerformancePayload>(`/api/v1/app/admin/performance?${params.toString()}`)
}

export function explainSql(sql: string, options: { analyze?: boolean; timeoutMs?: number } = {}) {
  return postJson<SqlExplainResult>("/api/v1/app/admin/performance/explain", {
    sql,
    analyze: options.analyze ?? false,
    timeout_ms: options.timeoutMs
  })
}
