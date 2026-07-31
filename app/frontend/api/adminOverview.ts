import { getJson } from "./client"

export type AdminOverviewPayload = {
  active_runs: {
    total: number
    by_trigger: Record<string, number>
  }
  queued_runs: {
    total: number
  }
  recent_failures_24h: {
    total: number
    by_trigger: Record<string, number>
  }
  github_rate_limits: Array<{
    email: string
    remaining: number
    limit: number
    resource: string | null
  }>
  github_api_blocked_users: Array<{
    id: number
    email: string
    reason: string | null
  }>
  provider_circuits: Array<{
    provider: string
    open: boolean
    reason: string | null
    retry_after: string | null
    failure_count: number
    job_count: number
    signature: string | null
  }>
  agent_session_capture_rate: {
    total: number
    captured: number
    rate: number | null
  }
  data_root_disk_usage: {
    hostname?: string | null
    path: string
    filesystem?: string
    total_bytes?: number
    used_bytes?: number
    available_bytes: number
    used_percent: number
    mounted_on?: string
    observed_at: string
    level: "ok" | "warning" | "critical" | string
  } | null
  worker_data_root_usages?: {
    hostname: string
    path: string
    used_percent: number
    available_bytes: number
    total_bytes: number
    level: string
    observed_at: string
  }[]
  workers: {
    total?: number
    stale?: number
    unreachable?: boolean
  }
  recurring: {
    overdue?: Array<{
      key: string
      age_seconds: number | null
      never_run?: boolean
    }>
    unreachable?: boolean
  }
  stuck: Array<{
    kind: string
    severity: "warn" | "alarm" | string
    reconciler_severity?: string
    attention_state?: string
    detail: string
    age_label: string
    run_id: number | null
    workflow_id: number | null
    workflow_slug?: string | null
    workflow_path?: string | null
    workflow_trigger_kind?: string | null
    step_kind?: string | null
    job_id: number | null
    job_path?: string | null
    has_transcript?: boolean
    issue?: Record<string, unknown> | null
    repair_plan?: Record<string, unknown> | null
    repair_execution?: Record<string, unknown> | null
  }>
}

export function fetchAdminOverview() {
  return getJson<AdminOverviewPayload>("/api/v1/app/admin/overview")
}
