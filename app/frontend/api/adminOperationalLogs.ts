import { getJson } from "./client"

export type OperationalLogLevel = "debug" | "info" | "warn" | "error" | "fatal" | "unknown"
export type OperationalLogRole = "web" | "worker"
export type OperationalLogRevisionScope = "current" | "all"

export type OperationalLogRow = {
  id: number
  occurred_at: string
  level: OperationalLogLevel
  role: string
  hostname: string
  app_revision?: string | null
  pid?: number | null
  source: string
  job_id?: number | null
  workflow_id?: number | null
  run_id?: number | null
  request_id?: string | null
  message: string
  context?: Record<string, string> | null
}

export type OperationalLogsPayload = {
  enabled: boolean
  retention_seconds: number
  current_revision: string
  revision_scope: OperationalLogRevisionScope
  filters: {
    query?: string | null
    since?: string | null
    until?: string | null
    level?: OperationalLogLevel | null
    role?: OperationalLogRole | null
    hostname?: string | null
  }
  pagination: {
    page: number
    per_page: number
    has_next_page: boolean
    has_previous_page: boolean
    next_page?: number | null
    previous_page?: number | null
  }
  logs: OperationalLogRow[]
  error?: {
    code: string
    message: string
  }
}

export function fetchAdminOperationalLogs(search = "") {
  return getJson<OperationalLogsPayload>(`/api/v1/app/admin/operational_logs${search}`)
}
