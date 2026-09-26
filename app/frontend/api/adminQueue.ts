import { getJson, postJson } from "./client"
import type { AdminFilteredPayload } from "./adminSmartFolders"
import type { WorkerHealthPayload } from "./adminOverview"

export type { WorkerHealthPayload } from "./adminOverview"

export const queueTabs = ["active", "pending", "failed", "recurring", "workers"] as const

export type QueueTab = (typeof queueTabs)[number]

export type QueueJob = {
  id: number
  class_name: string
  queue_name: string
  priority: number
  arguments: unknown[] | null
  created_at: string
  scheduled_at: string | null
  claimed_at?: string | null
  ready_at?: string | null
}

export type QueueFailure = {
  id: number
  job_id: number
  created_at: string
  class_name: string | null
  priority: number | null
  scheduled_at: string | null
  arguments: unknown[] | null
  exception_class: string | null
  message: string | null
}

export type QueueRecurringTask = {
  key: string
  class_name: string | null
  schedule: string
  last_run_at: string | null
  last_finished_at: string | null
}

export type QueueWorker = {
  pid: number
  hostname: string | null
  queues: string[] | string | null
  threads: number | null
  last_heartbeat_at: string | null
  stale: boolean
  status?: "current" | "stale" | string
}

export type QueueProcess = {
  kind: string
  pid: number
  hostname: string | null
  last_heartbeat_at: string | null
  stale?: boolean
  status?: "current" | "stale" | string
}

export type QueueSort = {
  column: string
  direction: "asc" | "desc"
}

export type QueuePagination = {
  page: number
  per_page: number
  total_pages: number
  has_previous_page: boolean
  has_next_page: boolean
  previous_page: number | null
  next_page: number | null
}

export type ActiveQueuePayload = AdminFilteredPayload & {
  jobs: QueueJob[]
  total: number
  pagination: QueuePagination
  sort: QueueSort
}

export type PendingQueuePayload = AdminFilteredPayload & {
  jobs: QueueJob[]
  total: number
  pagination: QueuePagination
  sort: QueueSort
}

export type FailedQueuePayload = AdminFilteredPayload & {
  since: string
  failures: QueueFailure[]
  total: number
  pagination: QueuePagination
  sort: QueueSort
}

export type RecurringQueuePayload = {
  tasks: QueueRecurringTask[]
  sort: QueueSort
}

export type WorkersQueuePayload = {
  workers: QueueWorker[]
  all_processes: QueueProcess[]
  sort: QueueSort
  worker_health?: WorkerHealthPayload
}

export type AdminQueuePayload =
  | ActiveQueuePayload
  | PendingQueuePayload
  | FailedQueuePayload
  | RecurringQueuePayload
  | WorkersQueuePayload

export function isQueueTab(value: string | undefined): value is QueueTab {
  return queueTabs.includes(value as QueueTab)
}

export function fetchAdminQueue(tab: QueueTab, search = "") {
  return getJson<AdminQueuePayload>(`/api/v1/app/admin/queue/${tab}${search}`)
}

export function reapStaleRuns() {
  return postJson<{ ok: boolean; message: string }>("/api/v1/app/admin/queue/reap_stale_runs")
}
