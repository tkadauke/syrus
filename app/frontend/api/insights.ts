import { getJson, patchJson, postJson } from "./client"

export type InsightEvidenceItem = {
  job_id: number | null
  run_id: number | null
  kind: string | null
  job_path: string | null
  run_transcript_path: string | null
}

export type InsightJobSummary = {
  id: number
  slug: string
  title: string
  state: string
  job_path: string
}

export type InsightSuggestion = {
  id: number
  title: string
  category: string
  severity: "low" | "medium" | "high"
  confidence: number
  state: "pending" | "accepted" | "dismissed"
  suggested_prompt: string | null
  memory_suggestion: string | null
  has_memory_suggestion: boolean
  evidence: InsightEvidenceItem[]
  job_slug: string
  job_path: string
  accepted_at: string | null
  dismissed_at: string | null
  created_at: string
  created_job: InsightJobSummary | null
}

export type InsightSuggestionsPayload = {
  repository: {
    id: number
    slug: string
    repository_path: string
    insights_path: string
  }
  suggestions: InsightSuggestion[]
}

export type InsightSuggestionUpdatePayload = {
  message: string
  suggestion: InsightSuggestion
  job?: InsightJobSummary | null
  memory_id?: number
}

export type AdminInsightSuggestion = InsightSuggestion & {
  repository: {
    id: number
    slug: string
    repository_path: string
    insights_path: string
  }
  user: {
    id: number
    display_name: string
  }
}

export type AdminInsightsPayload = {
  suggestions: AdminInsightSuggestion[]
}

export function fetchInsightSuggestions(repositoryId: string | number) {
  return getJson<InsightSuggestionsPayload>(`/api/v1/app/repositories/${repositoryId}/insight_suggestions`)
}

export function acceptInsightSuggestion(
  id: number,
  opts: { createJob?: boolean; prompt?: string; agentProvider?: string } = {}
) {
  return patchJson<InsightSuggestionUpdatePayload>(`/api/v1/app/insight_suggestions/${id}`, {
    action_type: "accept",
    create_job: opts.createJob ?? false,
    prompt: opts.prompt,
    agent_provider: opts.agentProvider
  })
}

export function dismissInsightSuggestion(id: number) {
  return patchJson<InsightSuggestionUpdatePayload>(`/api/v1/app/insight_suggestions/${id}`, {
    action_type: "dismiss"
  })
}

export function saveInsightMemory(id: number) {
  return patchJson<InsightSuggestionUpdatePayload>(`/api/v1/app/insight_suggestions/${id}`, {
    action_type: "save_memory"
  })
}

export function fetchAdminInsights() {
  return getJson<AdminInsightsPayload>("/api/v1/app/admin/insights")
}

export function promoteInsightMemory(id: number) {
  return postJson<{ message: string; memory_id: number }>(`/api/v1/app/admin/insights/${id}/promote_memory`, {})
}
