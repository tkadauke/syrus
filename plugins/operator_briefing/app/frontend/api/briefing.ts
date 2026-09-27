import { getJson, patchJson, postJson } from "@app/api/client"
import type { TypedArtifact } from "@app/api/artifacts"

export type BriefingRepository = {
  id: number
  slug: string
  path: string
}

export type BriefingRevision = {
  id: number
  revision_number: number
  generated_at: string | null
  content_blocks: BriefingBlock[]
}

export type BriefingRecord = {
  id: number
  slug: string
  live: boolean
  window_start: string | null
  window_end: string | null
  job: {
    id: number
    slug: string
    title: string
    state: string
    path: string
  }
  latest_revision: BriefingRevision | null
}

export type BriefingBlock =
  | { kind: "narrative"; payload: { text?: string | null; dive_candidates?: BriefingDiveCandidate[] | null } }
  | { kind: "chart"; payload: { chart_type?: "count_by_severity" | "count_by_state" | string | null; title?: string | null; data?: BriefingChartDatum[] | null } }
  | { kind: "image"; payload: BriefingArtifactReference }
  | { kind: "artifact"; payload: BriefingArtifactReference }
  | { kind: "link_card"; payload: { entity_type?: string | null; entity_id?: number | string | null; title?: string | null; path?: string | null; description?: string | null } }

export type BriefingDiveCandidate = {
  text: string
  prompt?: string | null
  evidence?: unknown[] | null
  topic_id?: number | null
}

export type BriefingChartDatum = {
  label: string
  value: number
}

export type BriefingArtifactReference = {
  workflow_id?: number | string | null
  type?: string | null
  title?: string | null
  caption?: string | null
  artifact?: TypedArtifact | null
}

export type BriefingRepoPayload = {
  repository: BriefingRepository
  current: BriefingRecord | null
  history: BriefingRecord[]
  status: {
    kind: "live" | "ready" | "no_activity" | string
    message: string | null
  }
}

export type BriefingSubscription = {
  id: number
  enabled: boolean
  repository: BriefingRepository
}

export type BriefingSourcePreference = {
  id: number
  source_key: string
  label: string
  description: string | null
  enabled: boolean
  weight: number
  suggested_by: "system" | "user" | "ai" | string
  confirmed_at: string | null
  pending: boolean
}

export type BriefingPayload = {
  settings: {
    cadence_expression: string
    budget_check_enabled: boolean
    agent_provider: string | null
    last_scheduled_at: string | null
    budget_gate: {
      skip: boolean
      reason: string | null
    }
  }
  source_preferences: BriefingSourcePreference[]
  source_preference_suggestions: BriefingSourcePreference[]
  repositories: BriefingRepoPayload[]
  subscriptions: BriefingSubscription[]
  generated_at: string
}

export type BriefingTopicPayload = {
  id: number
  slug: string
  title: string
  repository: BriefingRepository
  revisions: Array<{
    id: number
    revision_number: number
    generated_at: string | null
    narrative: string
    findings: string[]
    references: unknown[]
    briefing_id: number | null
    workflow_id: number | null
  }>
}

export type BriefingFeedbackResponse = {
  feedback: {
    id: number
    memory_entry_id: number | null
    sentiment: string | null
    note: string | null
  }
  briefing: BriefingPayload
}

export function fetchBriefing() {
  return getJson<BriefingPayload>("/api/v1/app/briefing")
}

export function fetchBriefingTopic(id: string | number) {
  return getJson<BriefingTopicPayload>(`/api/v1/app/briefing/topics/${id}`)
}

export function regenerateBriefing(repositoryId: number) {
  return postJson<BriefingPayload>(`/api/v1/app/briefing/repositories/${repositoryId}/regenerate`)
}

export function startBriefingDive(briefingId: number, input: { selected_text: string; prompt?: string; evidence?: unknown[] }) {
  return postJson<{ workflow_id: number; status: string; briefing: BriefingPayload }>(`/api/v1/app/briefing/${briefingId}/dive`, {
    dive: input
  })
}

export function discussBriefing(briefingId: number, message?: string) {
  return postJson<{ redirect_to: string }>(`/api/v1/app/briefing/${briefingId}/discuss`, {
    discussion: { message }
  })
}

export function updateBriefingSubscription(id: number, enabled: boolean) {
  return patchJson<BriefingPayload>(`/api/v1/app/briefing/subscriptions/${id}`, {
    subscription: { enabled }
  })
}

export function updateBriefingSourcePreference(id: number, enabled: boolean) {
  return patchJson<BriefingPayload>(`/api/v1/app/briefing/source_preferences/${id}`, {
    source_preference: { enabled }
  })
}

export function confirmBriefingSourcePreference(id: number) {
  return postJson<BriefingPayload>(`/api/v1/app/briefing/source_preferences/${id}/confirm`)
}

export function createBriefingFeedback(input: { briefing_id?: number; briefing_item_id?: number; sentiment?: string; note?: string }) {
  return postJson<BriefingFeedbackResponse>("/api/v1/app/briefing/feedback", {
    feedback: input
  })
}
