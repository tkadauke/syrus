import { getJson } from "./client"
import type { AdminEventFilterPayload } from "../components/AdminEventLogPanel"

export type AdminWorkUnitsPayload = AdminEventFilterPayload & {
  intents: WorkIntentSummary[]
  filters: Record<string, unknown> & {
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
  settings: {
    show_work_unit_debug: boolean
  }
}

export type WorkIntentSummary = {
  id: number
  kind: string
  label: string
  state: string
  priority: string | null
  scope_type: string
  scope_id: number | null
  delivery_track: string | null
  wait_reason: string | null
  wait_until: string | null
  wait_details: Record<string, unknown>
  requested_at: string | null
  satisfied_at: string | null
  cancelled_at: string | null
  source_type: string | null
  source_id: number | null
  source_ref: string | null
  target_ref: string | null
  repository: LinkedRepository | null
  source_repository: LinkedRepository | null
  target_repository: LinkedRepository | null
  actor: { id: number; display_name: string; email_address: string } | null
  jobs: LinkedJob[]
  units: WorkUnitSummary[]
}

export type WorkUnitSummary = {
  id: number
  kind: string
  label: string
  state: string
  scope_type: string
  scope_id: number | null
  delivery_track: string | null
  blocked_reason: string | null
  blocked_until: string | null
  blocked_details: Record<string, unknown>
  pause_requested: boolean
  preemption_reason: string | null
  source_ref: string | null
  target_ref: string | null
  created_at: string | null
  started_at: string | null
  finished_at: string | null
  repository: LinkedRepository | null
  source_repository: LinkedRepository | null
  target_repository: LinkedRepository | null
  workflow: LinkedWorkflow | null
  members: Array<{ role: string; job: LinkedJob | null }>
}

export type LinkedRepository = {
  id: number
  slug: string
  path: string
}

export type LinkedJob = {
  id: number
  slug: string
  title: string | null
  state: string
  path: string
}

export type LinkedWorkflow = {
  id: number
  slug: string
  trigger_kind: string | null
  state: string
  path: string
}

export function fetchAdminWorkUnits(search = "", signal?: AbortSignal) {
  return getJson<AdminWorkUnitsPayload>(`/api/v1/app/admin/work_units${search}`, { signal })
}
