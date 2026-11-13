import { getJson, getJsonIfModified } from "./client"

export type TranscriptSummary = {
  model: string | null
  total_turns: number | null
  total_tool_calls: number
  total_cost_usd: number | null
  exit_reason: string | null
  tool_call_counts: Record<string, number>
  mcp_tool_called: boolean
}

export type TranscriptEvent = {
  index?: number
  kind: string
  timestamp: string | null
  data: Record<string, unknown>
  body_truncated?: boolean
}

export type TranscriptPayload = {
  run_id: number
  job_id: number
  job_slug?: string | null
  step_kind: string | null
  workflow_trigger_kind: string | null
  finished: boolean
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

export function fetchAdminTranscript(runId: string, page: number, per: number, afterEvent?: number) {
  const cursor = afterEvent == null ? "" : `&after_event=${afterEvent}`
  return getJsonIfModified<TranscriptPayload>(`/api/v1/app/admin/runs/${runId}/transcript?page=${page}&per=${per}${cursor}`)
}

export function fetchAdminTranscriptEvent(runId: number, eventIndex: number) {
  return getJson<TranscriptEvent>(`/api/v1/app/admin/runs/${runId}/transcript/events/${eventIndex}`)
}
