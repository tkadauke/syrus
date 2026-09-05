import { getJson, postJson } from "@app/api/client"
import type { FilterSchemaField } from "@app/components/FilterBar"

export type AgentActivitySessionJob = {
  id: number
  slug: string
  title: string | null
  state: string
}

export type AgentActivitySessionRepository = {
  id: number
  slug: string
}

export type AgentActivitySession = {
  id: number
  slug: string
  state: string
  step_kind: string
  role: string
  role_label: string
  agent_provider: string
  agent_outcome: string | null
  outcome_summary: string | null
  outcome_verdict: string | null
  started_at: string | null
  finished_at: string | null
  created_at: string | null
  duration_seconds: number | null
  transcript_path: string
  job: AgentActivitySessionJob | null
  repository: AgentActivitySessionRepository | null
  workflow_id: number | null
  trigger_kind: string | null
}

export type AgentActivitySessionsPayload = {
  sessions: AgentActivitySession[]
  total: number
  page: number
  per: number
  running_count: number
  filter: Record<string, unknown> | null
  filter_schema: FilterSchemaField[]
}

export type AgentActivityRunArtifacts = {
  job_id: number
  workflow_id: number | null
  run_id: number
  base_ref: string | null
  head_ref: string | null
  agent_diff: string | null
  agent_diff_bytes: number
  step_agent_diff?: string | null
  logs_count: number
  logs: Array<{ id: number; sequence: number; kind: string | null; chunk: string; created_at: string | null }>
}

export function fetchAgentActivitySessions(scope: "mine" | "admin", search = "") {
  const path = scope === "admin" ? "/api/v1/app/admin/agent_activity/sessions" : "/api/v1/app/agent_activity/sessions"
  return getJson<AgentActivitySessionsPayload>(`${path}${search}`)
}

export function fetchAgentActivityTranscript(transcriptPath: string) {
  return getJson<AgentActivityRunArtifacts>(transcriptPath)
}

export function recordAgentActivityFilterUsage(scope: "mine" | "admin", filter: Record<string, unknown>) {
  return postJson<{ recorded: boolean }>("/api/v1/app/filters/usage", {
    surface: scope === "admin" ? "agent_activity_admin" : "agent_activity",
    subject: "agent_activity",
    filter
  })
}
