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
  worker_health?: WorkerHealthPayload
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

export type WorkerHealthLevel = "ok" | "warning" | "critical" | "unknown" | string

export type WorkerHealthSample = {
  id: number
  hostname: string
  role: string
  version: string
  observed_at: string
  cpu_used_percent: number | null
  load_1m: number | null
  load_5m: number | null
  load_15m: number | null
  memory_used_percent: number | null
  memory_available_bytes: number | null
  memory_total_bytes: number | null
  data_root_used_percent: number | null
  data_root_available_bytes: number | null
  data_root_total_bytes: number | null
  cpu_pressure_some: number | null
  cpu_pressure_full: number | null
  io_pressure_some: number | null
  io_pressure_full: number | null
  raw_metrics: Record<string, unknown>
}

export type WorkerHealthSummary = {
  sample_count: number
  first_observed_at: string | null
  last_observed_at: string | null
  warning_count: number
  critical_count: number
  cpu_used_percent?: { avg: number; max: number } | null
  memory_used_percent?: { avg: number; max: number } | null
  data_root_used_percent?: { avg: number; max: number } | null
  load_1m?: { avg: number; max: number } | null
  load_5m?: { avg: number; max: number } | null
  load_15m?: { avg: number; max: number } | null
  cpu_pressure_some?: { avg: number; max: number } | null
  cpu_pressure_full?: { avg: number; max: number } | null
  io_pressure_some?: { avg: number; max: number } | null
  io_pressure_full?: { avg: number; max: number } | null
}

export type WorkerHealthMinuteBucket = WorkerHealthSummary & {
  minute: string
}

export type CurrentWorkerHealth = {
  id: number
  hostname: string
  role: string
  version: string
  started_at: string | null
  last_heartbeat_at: string | null
  seconds_since_heartbeat: number | null
  stale: boolean
  health: {
    level: WorkerHealthLevel
    reasons: string[]
  }
  sample: WorkerHealthSample | null
  trend: WorkerHealthSummary
}

export type WorkerHealthHost = {
  hostname: string
  status?: "current" | "historical" | string
  current: CurrentWorkerHealth | null
  windows: Record<string, WorkerHealthSummary>
  minute_buckets: WorkerHealthMinuteBucket[]
  recent_samples: WorkerHealthSample[]
}

export type WorkerHealthPayload = {
  generated_at: string
  range: {
    since: string
    until: string
  }
  current_sample_window_seconds: number
  minute_bucket: {
    granularity_seconds: number
    window_minutes: number
    max_window_minutes: number
  }
  current: CurrentWorkerHealth[]
  hosts: WorkerHealthHost[]
}

export function fetchAdminOverview() {
  return getJson<AdminOverviewPayload>("/api/v1/app/admin/overview")
}
