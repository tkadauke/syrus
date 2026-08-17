import { getJson } from "./client"

export type ReconcilerActivityEvent = {
  id: number
  event_type: string
  severity: "info" | "warn" | "error" | "alarm" | string
  source: string
  message: string
  issue_kind: string | null
  repair_action: string | null
  repair_status: string | null
  occurred_at: string
  details: Record<string, unknown>
  job: { id: number; slug: string; title: string | null; path: string } | null
  workflow: { id: number; slug: string; trigger_kind: string | null; state: string; path: string } | null
  run: { id: number; state: string; path: string } | null
}

export type AdminReconcilerActivityPayload = {
  events: ReconcilerActivityEvent[]
  event_types: string[]
  filters: {
    event_type: string | null
    job_id: number | null
    workflow_id: number | null
    run_id: number | null
    sort: string
    direction: "asc" | "desc"
  }
  pagination: {
    page: number
    per_page: number
    total: number
    total_pages: number
    first_item: number
    last_item: number
    previous_path: string | null
    next_path: string | null
  }
}

export function fetchAdminReconcilerActivity(search = "", signal?: AbortSignal) {
  return getJson<AdminReconcilerActivityPayload>(`/api/v1/app/admin/reconciler_activity${search}`, { signal })
}
