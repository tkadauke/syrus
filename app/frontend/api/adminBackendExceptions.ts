import { getJson } from "./client"
import type { AdminEventFilterPayload, AdminEventTimelineBucket } from "../components/AdminEventLogPanel"
import type { EventAction } from "./eventActions"

export type BackendExceptionRevisionScope = "current" | "all"

export type BackendExceptionEventRow = {
  id: number
  occurred_at: string | null
  app_revision: string | null
  fingerprint: string
  source: string
  role: string | null
  hostname: string | null
  pid: number | null
  request_id: string | null
  exception_class: string
  message: string
  backtrace: string | null
  controller: string | null
  action: string | null
  method: string | null
  path: string | null
  status: number | null
  job_class: string | null
  active_job_id: string | null
  queue_name: string | null
  executions: number | null
  job_id: number | null
  workflow_id: number | null
  run_id: number | null
  metadata: Record<string, unknown>
  actions?: EventAction[]
}

export type BackendExceptionEventsPayload = AdminEventFilterPayload & {
  current_revision: string
  revision_scope: BackendExceptionRevisionScope
  filters: Record<string, string | null>
  sources: string[]
  pagination: {
    page: number
    per_page: number
    has_next_page: boolean
    has_previous_page: boolean
    next_page?: number | null
    previous_page?: number | null
  }
  timeline: AdminEventTimelineBucket[]
  events: BackendExceptionEventRow[]
}

export function fetchAdminBackendExceptions(search = "") {
  return getJson<BackendExceptionEventsPayload>(`/api/v1/app/admin/backend_exceptions${search}`)
}
