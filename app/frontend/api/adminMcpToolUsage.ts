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
  owner_type: "core" | "plugin"
  owner_name: string
  recommendation_target: string
  card_status: "missing" | "weak" | "registered"
  classification?: McpToolCardCoverageClassification
}

export type McpToolCardCoverageClassification =
  | "custom_card"
  | "plugin_custom_card"
  | "generic_card_acceptable"
  | "hidden_ack_only"
  | "intentionally_obscure_deferred"
  | "unclassified"

export type McpToolCardCoverageRow = {
  tool_name: string
  owner_type: "core" | "plugin"
  owner_name: string
  recommendation_target: string
  tier: string | null
  mutation: boolean | null
  card_status: "missing" | "weak" | "registered"
  card_owner_type: "core" | "plugin" | null
  card_owner_name: string | null
  card_path: string | null
  has_custom_card: boolean
  classification: McpToolCardCoverageClassification
  classification_reason: string
}

export type McpToolCardGaps = {
  high_volume_without_custom_card: McpToolCardGapRow[]
  high_error_with_weak_or_no_custom_card: McpToolCardGapRow[]
  unused_advertised_tools: McpToolCardGapRow[]
  classification_counts: Partial<Record<McpToolCardCoverageClassification, number>>
  classified_tools: McpToolCardCoverageRow[]
  unclassified_tools: McpToolCardCoverageRow[]
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
}

export function fetchAdminMcpToolUsage(search = "") {
  return getJson<McpToolUsagePayload>(`/api/v1/app/admin/mcp_tool_usage${search}`)
}
