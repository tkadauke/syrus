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

export type McpToolUsagePayload = {
  window: { start: string; end: string }
  surface: string
  totals: { calls: number; errors: number }
  top_tools: McpToolUsageToolRow[]
  error_rates: McpToolUsageToolRow[]
  surface_breakdown: McpToolUsageBreakdownRow[]
  provider_breakdown: McpToolUsageBreakdownRow[]
  server_breakdown: McpToolUsageBreakdownRow[]
  sidecar_mode_breakdown: McpToolUsageBreakdownRow[]
  unused_advertised_tools: string[]
  recent_calls: McpToolUsageRecentCall[]
}

export function fetchAdminMcpToolUsage(search = "") {
  return getJson<McpToolUsagePayload>(`/api/v1/app/admin/mcp_tool_usage${search}`)
}
