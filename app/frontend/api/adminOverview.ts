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
    decision?: Record<string, unknown>
    runs?: Array<Record<string, unknown>>
    evidence_records?: Array<Record<string, unknown>>
    consumers?: Record<string, unknown>
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
  resource_admission?: ResourceAdmissionDiagnosticsPayload
  chat_scoped_events: {
    window_hours: number
    total: number
    by_state: Record<string, number>
    by_decision: {
      no_op: number
      respond: number
      act: number
    }
    failures: ChatScopedEventObservation[]
    recent: ChatScopedEventObservation[]
  }
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
  stuck_pagination: {
    page: number
    per_page: number
    total: number
    total_pages: number
    first_item: number
    last_item: number
    previous_path: string | null
    next_path: string | null
  }
  stuck_snapshot?: {
    captured_at: string | null
    stale: boolean
  }
}

export type ResourceAdmissionCost = {
  duration_seconds?: number | null
  cpu_pressure?: number | null
  io_pressure?: number | null
  memory_used_percent?: number | null
}

export type ResourceAdmissionJobRef = {
  id: number
  slug: string
  title: string | null
  state: string
  priority: string | null
  path: string
}

export type ResourceAdmissionPressure = {
  cpu_pressure?: number | null
  io_pressure?: number | null
  memory_used_percent?: number | null
  host_pressure_level?: string | null
  host_pressure_reasons?: string[]
  host_sample_count?: number
  host_sample_confidence?: string
  process_attribution_confidence?: string
  process_attribution_method?: string
  process_sample_count?: number
  process_attributed_sample_count?: number
  process_cpu_seconds?: number | null
  process_io_bytes?: number | null
  process_memory_bytes?: number | null
}

export type ResourceAdmissionConsumer = {
  run_id: number
  job_id: number
  workflow_id?: number | null
  step_kind?: string | null
  grader_name?: string | null
  repository?: string | null
  host?: string | null
  state?: string
  started_at?: string | null
  finished_at?: string | null
  wall_time_seconds?: number | null
  heartbeat_age_seconds?: number | null
  job?: ResourceAdmissionJobRef | null
  workflow_path?: string | null
  pressure?: ResourceAdmissionPressure | null
  estimated_remaining_cost?: ResourceAdmissionCost | null
  prediction?: {
    confidence_level?: string
    attribution_confidence_level?: string
    sample_count?: number
    attributed_sample_count?: number
    prediction_source?: string
    fallback_reason?: string | null
  } | null
}

export type ResourceAdmissionDelayedWork = {
  workflow_id: number
  job_id: number
  trigger_kind: string
  reason?: string | null
  action?: string | null
  delay_until?: string | null
  delayed_at?: string | null
  next_check_at?: string | null
  job?: ResourceAdmissionJobRef | null
  workflow_path?: string | null
  decision?: Record<string, unknown>
  pressure?: {
    candidate?: ResourceAdmissionCost & Record<string, unknown>
    active?: Record<string, unknown>
    projected?: ResourceAdmissionCost & Record<string, unknown>
    host?: Record<string, unknown>
  } | null
  estimated_remaining_cost?: ResourceAdmissionCost | null
  details?: Record<string, unknown>
}

export type ResourceAdmissionProfile = {
  id: number
  repository?: string | null
  agent_provider: string
  trigger_kind: string
  job_kind?: string | null
  step_kind: string
  grader_name?: string | null
  confidence_level: string
  attribution_confidence_level: string
  attribution_quality: string
  sample_count: number
  attributed_sample_count: number
  process_attributed_sample_count: number
  host_pressure_sample_count: number
  prediction_source: string
  fallback_reason?: string | null
  predicted_command_cost: ResourceAdmissionCost
  last_observed_at?: string | null
}

export type ResourceAdmissionOverride = ResourceAdmissionDelayedWork & {
  override?: boolean
  decided_at?: string | null
}

export type ResourceAdmissionDiagnosticsPayload = {
  generated_at: string
  windows: {
    recent_hours: number
    delayed_hours: number
  }
  active_consumers: ResourceAdmissionConsumer[]
  recent_top_consumers: ResourceAdmissionConsumer[]
  delayed_work: ResourceAdmissionDelayedWork[]
  low_confidence_profiles: ResourceAdmissionProfile[]
  admission_overrides: ResourceAdmissionOverride[]
}

export type ChatScopedEventObservation = {
  id: number
  source_kind: string
  summary: string
  severity?: string | null
  delivery_state: string
  evaluator_state: string
  decision?: "no_op" | "respond" | "act" | string | null
  reason?: string | null
  dedupe_key?: string | null
  error?: string | null
  created_at: string
  evaluated_at?: string | null
  chat?: {
    id: number
    title: string
    system_kind?: string | null
    path: string
  } | null
  repository?: {
    id: number
    slug: string
  } | null
  job?: {
    id: number
    slug: string
    path: string
  } | null
  epic?: {
    id: number
    slug: string
    path: string
  } | null
  proposal_id?: number | null
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
