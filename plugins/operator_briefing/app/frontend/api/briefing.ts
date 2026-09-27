import { getJson, patchJson, postJson } from "@app/api/client"

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
  | { kind: "narrative"; payload: { text?: string | null } }
  | { kind: "link_card"; payload: { entity_type?: string | null; entity_id?: number | string | null; title?: string | null; path?: string | null; description?: string | null } }

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
  repositories: BriefingRepoPayload[]
  subscriptions: BriefingSubscription[]
  generated_at: string
}

export function fetchBriefing() {
  return getJson<BriefingPayload>("/api/v1/app/briefing")
}

export function regenerateBriefing(repositoryId: number) {
  return postJson<BriefingPayload>(`/api/v1/app/briefing/repositories/${repositoryId}/regenerate`)
}

export function updateBriefingSubscription(id: number, enabled: boolean) {
  return patchJson<BriefingPayload>(`/api/v1/app/briefing/subscriptions/${id}`, {
    subscription: { enabled }
  })
}
