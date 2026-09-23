import { getJson } from "./client"

export type McpToolUsageSurface = "workflow" | "chat"

export type McpToolUsageToolRow = {
  tool_name: string
  server_name: string | null
  calls: number
  errors: number
  error_rate: number
}

export type McpToolUsageBreakdownRow = {
  calls: number
  errors: number
  error_rate: number
  surface?: string | null
  provider?: string | null
  server_name?: string | null
  sidecar_mode?: string | null
}

export type McpToolUsageRecentCall = {
  id: number
  occurred_at: string
  surface: string
  provider: string | null
  tool_name: string
  server_name: string | null
  status: string
  error: boolean
  error_class: string | null
  error_message_summary: string | null
  sidecar_mode: string | null
  job_id: number | null
  job_path: string | null
  workflow_id: number | null
  workflow_path: string | null
  run_id: number | null
  run_path: string | null
  chat_session_id: number | null
  chat_path: string | null
}

export type McpToolCardGapRow = {
  tool_name: string
  calls?: number
  errors?: number
  error_rate?: number
  result_bytes?: number
  last_used_at?: string | null
  server_names?: string[]
  owner_type: "core" | "plugin"
  owner_name: string
  recommendation_target: string
  card_status: "missing" | "weak" | "registered" | "generic" | "deferred" | "hidden"
  recommendation?: "custom_card_next" | "watch" | "ignore_for_now"
}

export type McpToolCardGaps = {
  ranked_gaps: McpToolCardGapRow[]
  high_volume_without_custom_card: McpToolCardGapRow[]
  high_error_with_weak_or_no_custom_card: McpToolCardGapRow[]
  unused_advertised_tools: McpToolCardGapRow[]
  unclassified_advertised_tools: McpToolCardGapRow[]
}

// One canonical McpStartupTiming phase (see app/services/mcp_startup_timing.rb),
// with the latency distribution -- across every recorded turn in the window --
// of how long it took to reach that phase since the turn's earliest observed
// phase (normally agent_process_spawn).
export type McpStartupPhaseLatencyRow = {
  phase: string
  count: number
  avg_ms: number | null
  p50_ms: number | null
  p95_ms: number | null
  max_ms: number | null
}

export type McpStartupTimingSection = {
  window: { start: string; end: string }
  filters: { provider: string | null; server_name: string | null }
  phase_latency: McpStartupPhaseLatencyRow[]
  turns_observed: number
  stalled_turns: number
}

export type McpToolUsagePayload = {
  window: { start: string; end: string }
  surface: string
  filters: {
    tool_name: string | null
    server_name: string | null
  }
  totals: { calls: number; errors: number }
  top_tools: McpToolUsageToolRow[]
  error_rates: McpToolUsageToolRow[]
  surface_breakdown: McpToolUsageBreakdownRow[]
  provider_breakdown: McpToolUsageBreakdownRow[]
  server_breakdown: McpToolUsageBreakdownRow[]
  sidecar_mode_breakdown: McpToolUsageBreakdownRow[]
  unused_advertised_tools: string[]
  custom_card_gaps: McpToolCardGaps
  recent_calls: McpToolUsageRecentCall[]
  startup_timing: McpStartupTimingSection
}

export function fetchAdminMcpToolUsage(search = "") {
  return getJson<McpToolUsagePayload>(`/api/v1/app/admin/mcp_tool_usage${search}`)
}
