import { getJson } from "@app/api/client"

export type RepositoryThroughputConfidence = "none" | "low" | "medium" | "high"

export type RepositoryThroughputRate = {
  count: number
  per_hour: number
  sample_count: number
  confidence: RepositoryThroughputConfidence
}

export type RepositoryThroughputRatio = {
  numerator: number
  denominator: number
  value: number | null
  confidence: RepositoryThroughputConfidence
}

export type RepositoryThroughputDuration = {
  sample_count: number
  confidence: RepositoryThroughputConfidence
  average: number | null
  p50: number | null
  p95: number | null
}

export type RepositoryThroughputWindowKey = "1h" | "4h" | "24h" | "7d" | "last_active"

export type RepositoryThroughputWindow = {
  range: { start: string; end: string; hours: number }
  pr_creation: RepositoryThroughputRate & {
    total_observed_count: number
    series: {
      syrus_authored: RepositoryThroughputRate
      external: RepositoryThroughputRate
      fork_review: RepositoryThroughputRate
    }
  }
  output: {
    commits: RepositoryThroughputRate
    loc: RepositoryThroughputRate & {
      additions: number
      deletions: number
      net: number
      unavailable_sample_count: number
    }
    by_job: Array<{
      job_id: number
      pr_source: string
      commit_count: number
      sample_count: number
      diff_sample_count: number
      unavailable_sample_count: number
      additions: number
      deletions: number
      net: number
    }>
  }
  landing: {
    landing_units: RepositoryThroughputRate
    jobs_landed: RepositoryThroughputRate
    attempts: {
      total_count: number
      successful: RepositoryThroughputRate
      failed: RepositoryThroughputRate
      cancelled: RepositoryThroughputRate
      deferred: RepositoryThroughputRate
    }
    unit_types: {
      auto_merge: { landing_units: number; jobs_landed: number }
      merge_train: { landing_units: number; jobs_landed: number }
    }
    merge_train_size: {
      sample_count: number
      confidence: RepositoryThroughputConfidence
      average: number | null
      max: number | null
      values: number[]
    }
    approved_to_landing_latency_seconds: RepositoryThroughputDuration
    landing_start_to_closed_latency_seconds: RepositoryThroughputDuration
    grader_phase_duration_seconds: RepositoryThroughputDuration
    mergeability_rebase_wait_seconds: RepositoryThroughputDuration
    base_moved_regrade_count: number
    reused_landing_validation_count: number
    current_optimistic_capacity: {
      sample_count: number
      confidence: RepositoryThroughputConfidence
      average_successful_unit_wall_time_seconds: number | null
      estimated_landing_units_per_hour: number
      estimated_jobs_landed_per_hour: number
      average_jobs_per_landing_unit: number | null
    }
  }
  landing_waste: {
    failed_landing_attempts_per_successful_landing: RepositoryThroughputRatio
    failed_or_cancelled_landing_workflow_seconds: number
    failed_or_cancelled_landing_workflow_count: number
    deferred_landing_attempt_count: number
    failed_train_cooldown_seconds: number
    failed_train_cooldown_remaining_seconds: number
    rebase_churn_workflow_count: number
    rebase_churn_seconds: number
    landing_blocking_rebase_count: number
  }
  review_funnel: {
    jobs_with_pr_feedback: number
    jobs_with_feedback_before_approval: number
    feedback_rounds: number
    jobs_approved_immediately_without_feedback: number
    approval_sources: Record<string, { count: number; sample_count: number; confidence: RepositoryThroughputConfidence }>
    pr_open_to_first_feedback_seconds: RepositoryThroughputDuration
    feedback_to_addressed_seconds: RepositoryThroughputDuration
    pr_open_to_approval_seconds: RepositoryThroughputDuration
    approval_latency_seconds: RepositoryThroughputDuration
    approval_to_landing_start_seconds: RepositoryThroughputDuration
    approval_to_landing_latency_seconds: RepositoryThroughputDuration
    approval_to_landed_seconds: RepositoryThroughputDuration
    approval_count: number
    approval_vote_count: number
    pr_opened_count: number
  }
  samples: {
    jobs_seen: number
    prs_opened: number
    output_runs_with_diffs: number
    landed_jobs: number
    landing_workflows: number
    landing_units: number
    approvals: number
    approval_votes: number
    feedback_comments: number
  }
}

export type RepositoryThroughputMetricsPayload = {
  version: number
  repository_id: number
  generated_at: string
  windows: Record<RepositoryThroughputWindowKey, RepositoryThroughputWindow>
}

export function fetchRepositoryThroughputMetrics(id: number | string) {
  return getJson<RepositoryThroughputMetricsPayload>(`/api/v1/app/repositories/${id}/throughput_metrics`)
}
