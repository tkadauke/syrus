import { getJson, postJson } from "@app/api/client"
import type { FilterSchemaField } from "@app/components/FilterBar"

export type WorkerTimelineBlockedInfo = {
  blocked_reason: string | null
  blocked_since: string | null
  blocked_details: Record<string, unknown>
  next_check_at: string | null
  available: boolean
  historical: boolean
}

export type WorkerTimelineSpan = {
  worker_storage_key: string | null
  queue_role: string | null
  hostname: string | null
  pid: number | null
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
  key: string
  worker_storage_key: string | null
  queue_role: string | null
  hostname: string | null
  pid: number | null
  instance: WorkerTimelineInstance | null
  spans: WorkerTimelineSpan[]
}

export type WorkerTimelineMacroPayload = {
  range: { from: string; to: string }
  lanes: WorkerTimelineLane[]
  pending: WorkerTimelinePendingEntry[]
  filter: Record<string, unknown> | null
  filter_schema: FilterSchemaField[]
}

export type WorkerTimelineWaterfallWorkflow = {
  id: number
  job_id: number
  trigger_kind: string
  status: string
  started_at: string | null
  finished_at: string | null
  worker_storage_key: string | null
  queue_role: string | null
  hostname: string | null
  pid: number | null
  blocked: WorkerTimelineBlockedInfo
}

export type WorkerTimelineWaterfallRun = {
  id: number
  status: string
  iteration: number
  started_at: string | null
  finished_at: string | null
  last_heartbeat_at: string | null
}

export type WorkerTimelineWaterfallStep = {
  id: number
  kind: string
  status: string
  position: number
  iteration: number
  started_at: string | null
  finished_at: string | null
  worker_storage_key: string | null
  queue_role: string | null
  hostname: string | null
  pid: number | null
  runs: WorkerTimelineWaterfallRun[]
  blocked?: WorkerTimelineBlockedInfo
}

export type WorkerTimelineWaterfallPayload = {
  workflow: WorkerTimelineWaterfallWorkflow
  steps: WorkerTimelineWaterfallStep[]
}

export type WorkerTimelineFilterUsageInput = {
  filter: Record<string, unknown>
}

export type WorkerTimelineFilterUsagePayload = {
  recorded: boolean
}

export function fetchWorkerTimelineMacro(search = "") {
  return getJson<WorkerTimelineMacroPayload>(`/api/v1/app/admin/worker_timeline/macro${search}`)
}

export function fetchWorkerTimelineWorkflow(workflowId: string) {
  return getJson<WorkerTimelineWaterfallPayload>(`/api/v1/app/admin/worker_timeline/workflow?id=${encodeURIComponent(workflowId)}`)
}

export function recordWorkerTimelineFilterUsage(input: WorkerTimelineFilterUsageInput) {
  return postJson<WorkerTimelineFilterUsagePayload>("/api/v1/app/filters/usage", {
    surface: "worker_timeline",
    subject: "worker_timeline",
    filter: input.filter
  })
}
