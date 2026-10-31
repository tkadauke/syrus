import { getJson } from "@app/api/client"
import type { RepositoryTab } from "@app/api/repositories"

export type PipelineItem = {
  id: number
  slug: string
  title: string
  state: string
  needs_attention: boolean
  attention_reason?: string
  pinned?: boolean
  age_seconds: number
  evidence: { type: string; state?: string; stage_name?: string }
}

export type PipelineGroup = {
  key: string
  label: string
  epic?: { id: number; slug: string; title: string }
  total: number
  stage_totals: Record<string, number>
}

export type PipelineDrillDown = {
  stage: string
  page: number
  limit: number
  total: number
  next_page: number | null
  items: PipelineItem[]
}

export type PipelineStage = {
  key: string
  label: string
  kind: "lifecycle" | "deployment"
  total: number
  attention_count: number
  aging_count: number
  oldest_age_seconds: number | null
  highlighted_items: PipelineItem[]
}

export type PipelinePayload = {
  repository: { id: number; slug: string }
  generated_at: string
  tabs: RepositoryTab[]
  stages: PipelineStage[]
  groups: PipelineGroup[]
  drill_down?: PipelineDrillDown
}

export function fetchPipelineStage(repositoryId: string, stage: string, page = 1) {
  const params = new URLSearchParams({ stage, page: String(page) })
  return getJson<PipelinePayload>(`/api/v1/app/repositories/${repositoryId}/sdlc_pipeline?${params}`)
}

export function fetchPipeline(repositoryId: string) {
  return getJson<PipelinePayload>(`/api/v1/app/repositories/${repositoryId}/sdlc_pipeline`)
}
