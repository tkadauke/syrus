import { getJson } from "./client"

export type BrowserErrorRevisionScope = "current" | "all"

export type BrowserErrorEventRow = {
  id: number
  occurred_at: string
  app_revision?: string | null
  fingerprint: string
  name?: string | null
  message: string
  stack?: string | null
  component_stack?: string | null
  url?: string | null
  path?: string | null
  route_id?: string | null
  route_params?: Record<string, unknown> | null
  trace_id?: string | null
  user_agent?: string | null
  viewport?: Record<string, unknown> | null
  feature_flags?: Record<string, unknown> | null
  recent_api_requests?: Array<Record<string, unknown>> | null
  recent_errors?: Array<Record<string, unknown>> | null
  metadata?: Record<string, unknown> | null
  user: {
    id: number
    display_name?: string | null
    email_address?: string | null
  }
}

export type BrowserErrorEventsPayload = {
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
  events: BrowserErrorEventRow[]
}

export function fetchAdminBrowserErrors(search = "") {
  return getJson<BrowserErrorEventsPayload>(`/api/v1/app/admin/browser_errors${search}`)
}
