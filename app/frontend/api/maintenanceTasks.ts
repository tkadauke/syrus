import { getJson, postJson } from "./client"

export type MaintenanceTaskState = "pending" | "running" | "paused" | "succeeded" | "failed" | "cancelled" | "dismissed" | "not_needed"

export type MaintenanceTask = {
  id: number
  definition_key: string
  task_key: string
  state: MaintenanceTaskState
  recurrence: "one_off" | "repeatable"
  category: string
  title: string
  summary: string
  trigger_kind: string
  trigger_key: string
  required_role: string
  current_step_key: string | null
  current_step_title: string | null
  total_units: number
  completed_units: number
  failed_units: number
  progress_percent: number
  eta_seconds: number | null
  started_at: string | null
  finished_at: string | null
  paused_at: string | null
  cancelled_at: string | null
  dismissed_at: string | null
  last_error: string | null
  pending_reason: string | null
  documentation: string | null
  steps: Array<{ key: string; title: string; description: string | null }>
  paths: { admin: string; api: string }
}

export type MaintenanceTaskEvent = {
  id: number
  level: string
  step_key: string | null
  step_title: string | null
  message: string
  units_done: number | null
  units_total: number | null
  created_at: string
}

export type MaintenanceSidebarPayload = {
  tasks: MaintenanceTask[]
}

export type AdminMaintenanceTasksPayload = {
  tasks: MaintenanceTask[]
  definitions: Array<{ key: string; title: string; summary: string; category: string; recurrence: string; required_role: string }>
  filter?: Record<string, unknown> | null
  filter_schema?: Array<Record<string, unknown>>
  filters: Record<string, unknown>
}

export type AdminMaintenanceTaskDetailPayload = MaintenanceTask & {
  events: MaintenanceTaskEvent[]
}

export function fetchMaintenanceSidebar(signal?: AbortSignal) {
  return getJson<MaintenanceSidebarPayload>("/api/v1/app/maintenance_tasks/sidebar", { signal })
}

export function fetchAdminMaintenanceTasks(search: string, signal?: AbortSignal) {
  return getJson<AdminMaintenanceTasksPayload>(`/api/v1/app/admin/maintenance_tasks${search}`, { signal })
}

export function fetchAdminMaintenanceTask(id: string | number, signal?: AbortSignal) {
  return getJson<AdminMaintenanceTaskDetailPayload>(`/api/v1/app/admin/maintenance_tasks/${id}`, { signal })
}

export function runMaintenanceTaskAction(id: string | number, action: "start" | "pause" | "resume" | "cancel" | "dismiss") {
  return postJson<AdminMaintenanceTaskDetailPayload>(`/api/v1/app/admin/maintenance_tasks/${id}/${action}`)
}

export function discoverMaintenanceTasks() {
  return postJson<AdminMaintenanceTasksPayload>("/api/v1/app/admin/maintenance_tasks/discover")
}
