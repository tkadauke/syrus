import { getJson } from "./client"

export type WorkflowActivityEvent = {
  id: number
  event_type: string
  severity: "info" | "warn" | "error" | string
  source: string
  message: string
  occurred_at: string
  trigger_kind: string | null
  workflow_state: string | null
  step_kind: string | null
  run_state: string | null
  reason_key: string | null
  duration_ms: number | null
  metadata: Record<string, unknown>
  job: { id: number; slug: string; title: string | null; path: string } | null
  workflow: { id: number; slug: string; trigger_kind: string | null; state: string; path: string } | null
  run: { id: number; state: string; path: string } | null
}

export type AdminWorkflowActivityPayload = {
  events: WorkflowActivityEvent[]
  event_types: string[]
  filters: {
    event_type: string | null
    job_id: number | null
    workflow_id: number | null
    run_id: number | null
    trigger_kind: string | null
    reason_key: string | null
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

export function fetchAdminWorkflowActivity(search = "", signal?: AbortSignal) {
  return getJson<AdminWorkflowActivityPayload>(`/api/v1/app/admin/activity${search}`, { signal })
}
