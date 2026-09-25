import { getJson, postJson } from "./client"
import type { FilterSchemaField } from "../components/FilterBar"

export type StuckItem = {
  kind: string
  severity: "warn" | "alarm" | string
  reconciler_severity?: string
  attention_state?: "repaired" | "waiting" | "auto_repairable" | "operator_action_required" | string
  detail: string
  age_label: string
  run_id: number | null
  workflow_id: number | null
  workflow_slug: string | null
  workflow_path: string | null
  workflow_trigger_kind: string | null
  step_kind: string | null
  job_id: number | null
  job_state: string | null
  job_path: string | null
  force_fail_path: string | null
  has_transcript: boolean
  issue?: Record<string, unknown> | null
  repair_plan?: Record<string, unknown> | null
  repair_execution?: Record<string, unknown> | null
}

export type AdminStuckPayload = {
  items: StuckItem[]
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
  snapshot?: {
    captured_at: string | null
    stale: boolean
  }
  filter?: Record<string, unknown> | null
  filter_schema?: FilterSchemaField[]
  filters?: Record<string, unknown> & {
    sort: string
    direction: "asc" | "desc"
  }
}

export function fetchAdminStuck(search = "", signal?: AbortSignal, refresh = false) {
  const params = new URLSearchParams(search)
  if (!params.get("page")) params.set("page", "1")
  if (refresh) params.set("refresh", "1")
  return getJson<AdminStuckPayload>(`/api/v1/app/admin/stuck?${params.toString()}`, { signal })
}

export function forceFailStuckJob(path: string) {
  return postJson<{ message?: string }>(path)
}
