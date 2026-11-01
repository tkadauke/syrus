import { getJson } from "@app/api/client"
import type { RepositoryTab } from "@app/api/repositories"
import type { AdminSmartFolder } from "@app/api/adminSmartFolders"
import type { FilterSchemaField } from "@app/components/FilterBar"

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
  paths: { job: string; workflow?: string; delivery?: string; release?: string }
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
  release_tail?: boolean
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
  evidence: { status: "complete" | "partial"; incomplete_count: number }
  drill_down?: PipelineDrillDown
  filter: Record<string, unknown>
  filter_schema: FilterSchemaField[]
  smart_folders: AdminSmartFolder[]
  active_smart_folder_id: number | null
  history?: PipelineHistory
}

export type HistoricalPlacement = {
  job_id: number
  stage: string
  item: Pick<PipelineItem, "id" | "slug" | "title" | "state" | "paths"> & {
    epic?: { id: number; slug: string; title: string }
    metadata_as_of: string
  }
}

export type PipelineHistory = {
  from: string
  to: string
  checkpoint: { at: string; placements: HistoricalPlacement[] }
  deltas: { at: string; job_id: number; from_stage: string | null; to_stage: string | null; item?: HistoricalPlacement }[]
  ticks: string[]
  traces: { job_id: number; segments: { stage: string; entered_at: string; left_at: string; dwell_seconds: number }[] }[]
  accuracy: { status: "reconstructed" | "partial" | "bounded"; message: string; truncated: boolean; legacy_job_count?: number }
}

export function fetchPipelineStage(repositoryId: string, stage: string, page = 1, search = "") {
  const params = new URLSearchParams(search)
  params.set("stage", stage)
  params.set("page", String(page))
  return getJson<PipelinePayload>(`/api/v1/app/repositories/${repositoryId}/sdlc_pipeline?${params}`)
}

export function fetchPipeline(repositoryId: string, search = "") {
  return getJson<PipelinePayload>(`/api/v1/app/repositories/${repositoryId}/sdlc_pipeline${search}`)
}
