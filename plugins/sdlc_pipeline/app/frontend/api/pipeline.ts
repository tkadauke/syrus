import { getJson } from "@app/api/client"
import type { RepositoryTab } from "@app/api/repositories"

export type PipelineItem = {
  id: number
  slug: string
  title: string
  state: string
  needs_attention: boolean
  age_seconds: number
  evidence: { type: string; state?: string; stage_name?: string }
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
  tabs: RepositoryTab[]
  stages: PipelineStage[]
}

export function fetchPipeline(repositoryId: string) {
  return getJson<PipelinePayload>(`/api/v1/app/repositories/${repositoryId}/sdlc_pipeline`)
}
