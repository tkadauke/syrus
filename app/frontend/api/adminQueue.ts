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
  arguments: unknown[] | null
  created_at: string
  claimed_at?: string | null
}

export type QueueFailure = {
  id: number
  created_at: string
  class_name: string | null
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

export type ActiveQueuePayload = AdminFilteredPayload & {
  jobs: QueueJob[]
}

export type PendingQueuePayload = AdminFilteredPayload & {
  jobs: QueueJob[]
  total: number
}

export type FailedQueuePayload = AdminFilteredPayload & {
  since: string
  failures: QueueFailure[]
}

export type RecurringQueuePayload = {
  tasks: QueueRecurringTask[]
}

export type WorkersQueuePayload = {
  workers: QueueWorker[]
  all_processes: QueueProcess[]
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
