import { getJson } from "./client"
import type { AdminEventFilterPayload, AdminEventTimelineBucket } from "../components/AdminEventLogPanel"
import type { EventAction } from "./eventActions"

export type BrowserErrorRevisionScope = "current" | "all"

export type BrowserErrorEventRow = {
  id: number
  occurred_at: string
  app_revision?: string | null
  fingerprint: string
  name?: string | null
  message: string
  path?: string | null
  route_id?: string | null
  trace_id?: string | null
  user: {
    id: number
    display_name?: string | null
    email_address?: string | null
  }
}

export type BrowserErrorDetail = {
  stack?: string | null
  component_stack?: string | null
  url?: string | null
  route_params: Record<string, unknown>
  user_agent?: string | null
  viewport: Record<string, unknown>
  feature_flags: Record<string, unknown>
  recent_api_requests: Array<Record<string, unknown>>
  recent_errors: Array<Record<string, unknown>>
  metadata: Record<string, unknown>
}

export type BrowserErrorControls = { filter_schema: NonNullable<AdminEventFilterPayload["filter_schema"]>; actions: EventAction[] }

export type BrowserErrorEventsPayload = AdminEventFilterPayload & {
  actions: EventAction[]
  current_revision: string
  revision_scope: BrowserErrorRevisionScope
  filters: {
    query?: string | null
    since?: string | null
    until?: string | null
    fingerprint?: string | null
    path?: string | null
  }
  pagination: {
    page: number
    per_page: number
    has_next_page: boolean
    has_previous_page: boolean
    next_page?: number | null
    previous_page?: number | null
  }
  timeline: AdminEventTimelineBucket[]
  events: BrowserErrorEventRow[]
}

export function fetchAdminBrowserErrors(search = "") {
  return getJson<BrowserErrorEventsPayload>(`/api/v1/app/admin/browser_errors${search}`)
}

export function fetchAdminBrowserErrorControls() {
  return getJson<BrowserErrorControls>("/api/v1/app/admin/browser_errors/controls")
}

export async function fetchAdminBrowserError(id: number) {
  return getJson<BrowserErrorEventRow & BrowserErrorDetail>(`/api/v1/app/admin/browser_errors/${id}`)
}
