import { getJson } from "./client"

export type TranscriptSummary = {
  session_id: string | null
  model: string | null
  cwd: string | null
  total_turns: number | null
  total_tool_calls: number
  total_cost_usd: number | null
  exit_reason: string | null
  tool_call_counts: Record<string, number>
  mcp_tool_called: boolean
  available_tools_at_init: string[]
}

export type TranscriptEvent = {
  kind: string
  timestamp: string | null
  data: Record<string, unknown>
}

export type TranscriptPayload = {
  run_id: number
  job_id: number
  step_kind: string | null
  workflow_trigger_kind: string | null
  session_id: string | null
  summary: TranscriptSummary
  pagination: {
    page: number
    per: number
    total_events: number
    total_pages: number
  }
  events: TranscriptEvent[]
}

export function fetchAdminTranscript(runId: string, page: number, per: number) {
  return getJson<TranscriptPayload>(`/api/v1/app/admin/runs/${runId}/transcript?page=${page}&per=${per}`)
}
