export type StartBlockedDetails = {
  kind?: string
  message?: string
  action?: string
  reason?: string
  delay_until?: string | null
  override?: boolean
  pressure?: {
    candidate?: StartBlockedPressureSnapshot
    active?: StartBlockedPressureSnapshot
    projected?: StartBlockedPressureSnapshot
    host?: {
      max_cpu_pressure?: number | null
      max_io_pressure?: number | null
      max_memory_used_percent?: number | null
      max_data_root_used_percent?: number | null
      sample_count?: number | null
      telemetry_state?: "present" | "stale" | "absent" | string
    }
  }
  details?: {
    decision_basis?: string
    prediction_source?: string
    fallback_reasons?: string[]
    active_high_cost_count?: number
    active_run_count?: number
    active_agentic_run_count?: number
    healthy_worker_count?: number
    telemetry_state?: "present" | "stale" | "absent" | string
    repository_active_workflow_count?: number
    candidate_high_cost?: boolean
    [key: string]: unknown
  }
  dependencies?: Array<{
    slug?: string
    job_id?: number
    branch_name?: string
    state?: string
  }>
}

export type StartBlockedPressureSnapshot = {
  duration_seconds?: number | null
  cpu_pressure?: number | null
  io_pressure?: number | null
  memory_used_percent?: number | null
  high_cost?: boolean
  high_cost_count?: number
  workflow_count?: number
  predicted_command_cost?: {
    duration_seconds?: number | null
    cpu_pressure?: number | null
    io_pressure?: number | null
    memory_used_percent?: number | null
    source?: string
    confidence?: string
  }
}
