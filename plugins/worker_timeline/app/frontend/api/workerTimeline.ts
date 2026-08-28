import { getJson } from "@app/api/client"

export type WorkerTimelineBlockedInfo = {
  blocked_reason: string | null
  blocked_since: string | null
  blocked_details: Record<string, unknown>
  next_check_at: string | null
  available: boolean
  historical: boolean
}

export type WorkerTimelineSpan = {
  workflow_id: number
  job_id: number
  started_at: string
  finished_at: string | null
  status: string
  label: string
  job_title: string | null
  blocked: WorkerTimelineBlockedInfo
}

export type WorkerTimelinePendingEntry = {
  workflow_id: number
  job_id: number
  label: string
  job_title: string | null
  created_at: string | null
  blocked: WorkerTimelineBlockedInfo
}

export type WorkerTimelineInstance = {
  id: number
  hostname: string
  started_at: string | null
  last_heartbeat_at: string | null
  finished_at: string | null
}

export type WorkerTimelineLane = {
  hostname: string | null
  pid: number | null
  instance: WorkerTimelineInstance | null
  spans: WorkerTimelineSpan[]
}

export type WorkerTimelineMacroPayload = {
  range: { from: string; to: string }
  lanes: WorkerTimelineLane[]
  pending: WorkerTimelinePendingEntry[]
}

export type WorkerTimelineFilterOption = { id: number; slug?: string; display_number?: string; title?: string }

export type WorkerTimelineFiltersPayload = {
  repositories: Array<{ id: number; slug: string }>
  epics: Array<{ id: number; display_number: string; title: string }>
  statuses: string[]
  hostnames: string[]
}

export function fetchWorkerTimelineMacro(search = "") {
  return getJson<WorkerTimelineMacroPayload>(`/api/v1/app/admin/worker_timeline/macro${search}`)
}

export function fetchWorkerTimelineFilters() {
  return getJson<WorkerTimelineFiltersPayload>("/api/v1/app/admin/worker_timeline/filters")
}
