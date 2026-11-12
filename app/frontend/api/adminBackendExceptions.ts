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
  request_id: string | null
  exception_class: string
  message: string
  method: string | null
  path: string | null
  status: number | null
  job_class: string | null
  queue_name: string | null
  job_id: number | null
  job_slug?: string | null
}

export type BackendExceptionDetail = {
  backtrace: string | null
  metadata: Record<string, unknown>
  request_context: Record<string, unknown>
  job_context: Record<string, unknown>
  hostname: string | null
  pid: number | null
}

export type BackendExceptionControls = { filter_schema: NonNullable<AdminEventFilterPayload["filter_schema"]>; actions: EventAction[]; sources: string[] }

export type BackendExceptionEventsPayload = AdminEventFilterPayload & {
  actions: EventAction[]
  current_revision: string
  revision_scope: BackendExceptionRevisionScope
  filters: Record<string, string | null>
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

export function fetchAdminBackendExceptionControls() {
  return getJson<BackendExceptionControls>("/api/v1/app/admin/backend_exceptions/controls")
}

export async function fetchAdminBackendException(id: number) {
  return getJson<BackendExceptionEventRow & BackendExceptionDetail>(`/api/v1/app/admin/backend_exceptions/${id}`)
}
