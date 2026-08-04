import { getJson, patchJson, postJson } from "./client"
import type { RepositoryTab } from "./repositories"

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
  proposal_type: "create_job" | "save_memory" | "remove_memory" | "revise_existing_insight" | "informational"
  suggested_prompt: string | null
  memory_suggestion: string | null
  has_memory_suggestion: boolean
  target_memory_id: number | null
  stale_memory_text: string | null
  stale_memory_evidence: string | null
  target_insight_id: number | null
  evidence: InsightEvidenceItem[]
  job_slug: string
  job_path: string
  accepted_at: string | null
  dismissed_at: string | null
  created_at: string
  created_job: InsightJobSummary | null
}

export type PaginationMeta = {
  total: number
  page: number
  per_page: number
  total_pages: number
}

export type InsightSuggestionCounts = {
  pending: number
  accepted: number
  dismissed: number
  all: number
}

export type InsightSuggestionsPayload = {
  repository: {
    id: number
    slug: string
    repository_path: string
    insights_path: string
  }
  tabs: RepositoryTab[]
  counts: InsightSuggestionCounts
  suggestions: InsightSuggestion[]
  meta: PaginationMeta
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
  meta: PaginationMeta
}

export function fetchInsightSuggestions(repositoryId: string | number, page = 1, perPage = 20, state = "all") {
  return getJson<InsightSuggestionsPayload>(
    `/api/v1/app/repositories/${repositoryId}/insight_suggestions?page=${page}&per_page=${perPage}&state=${encodeURIComponent(state)}`
  )
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

export function undismissInsightSuggestion(id: number) {
  return patchJson<InsightSuggestionUpdatePayload>(`/api/v1/app/insight_suggestions/${id}`, {
    action_type: "undismiss"
  })
}

export function saveInsightMemory(id: number) {
  return patchJson<InsightSuggestionUpdatePayload>(`/api/v1/app/insight_suggestions/${id}`, {
    action_type: "save_memory"
  })
}

export function acceptRemoveMemoryInsight(id: number) {
  return patchJson<InsightSuggestionUpdatePayload>(`/api/v1/app/insight_suggestions/${id}`, {
    action_type: "accept"
  })
}

export function fetchAdminInsights(page = 1, perPage = 20) {
  return getJson<AdminInsightsPayload>(`/api/v1/app/admin/insights?page=${page}&per_page=${perPage}`)
}

export function promoteInsightMemory(id: number) {
  return postJson<{ message: string; memory_id: number }>(`/api/v1/app/admin/insights/${id}/promote_memory`, {})
}
