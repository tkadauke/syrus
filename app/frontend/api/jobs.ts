import { deleteJson, getJson, patchJson, postForm, postJson } from "./client"

export type JobRepository = {
  id: number
  slug: string
  owner: string
  name: string
  default_branch: string
  review_policy: "self" | "two_person" | "final_say"
  feedback_policy: "auto" | "confirm"
  main_health: string
  landing_paused: boolean
  repository_path: string
}

export type PendingFeedbackComment = {
  id: number
  github_handle: string | null
  attributed_to: "member" | "external"
  pr_type: string
  comment_kind: string
  body: string | null
  comment_created_at: string | null
}

export type JobEpic = {
  id: number
  number: number
  display_number: string
  title: string
  state: string
  epic_path: string
}

export type JobRetryState = {
  classification: string | null
  classification_label: string
  retryable: boolean
  next_auto_retry_at: string | null
  retry_attempt_count: number
  retry_budget_remaining: number
  retry_budget: number
  auto_retry_exhausted: boolean
  provider_circuit_open: boolean
  retry_delayed_until: string | null
  retry_delay_reason: string | null
  state_label: string
}

export type JobRecord = {
  id: number
  kind: string
  state: string
  summary_state: string
  priority: string
  validity: string
  credential_mode: string | null
  agent_provider: string | null
  stack_base: string
  issue_number: number | null
  issue_url: string | null
  issue_title: string | null
  title_pending?: boolean
  issue_body: string | null
  branch_name: string | null
  pr_number: number | null
  pr_url: string | null
  external_pr_number: number | null
  external_pr_url: string | null
  pr_mergeable: boolean | null
  pr_mergeable_checked_at: string | null
  closure_reason: string | null
  landing_failure_reason: string | null
  retry_state?: JobRetryState
  approved_at: string | null
  approved_via: string | null
  owner_user_id: number | null
  owner_user: JobOwnerUser | null
  job_approvals: JobApprovalRecord[]
  approval_status: JobApprovalStatus | null
  claimed_at: string | null
  claimed_by_user: JobOwner | null
  claimed_by_current_user: boolean
  scheduled_task_id?: number | null
  scheduled_task?: JobScheduledTask | null
  total_cost_usd: number | null
  billed_runs_count: number
  source_chat: JobSourceChat | null
  workflows_count: number
  runs_count: number
  any_active_run: boolean
  prepare_skipped: boolean
  prepare_skip_reason: string | null
  created_at: string | null
  updated_at: string | null
  started_at: string | null
  finished_at: string | null
  needs_attention: boolean
  needs_attention_reason: string | null
  needs_attention_since: string | null
  grace_period_expires_at: string | null
}

export type JobOwnerUser = {
  id: number
  email_address: string
}

export type JobApprovalRecord = {
  id: number
  user_id: number
  user_email: string
  approved_at: string
}

export type JobApprovalStatus = {
  policy: "self" | "two_person" | "final_say"
  satisfied: boolean
  pending_description: string | null
  approvals_count: number
}

export type JobOwner = {
  id: number
  display_name: string
  profile_path: string
}

export type JobSourceChat = {
  chat_id: number
  chat_title: string | null
  proposal_id: number
  proposal_kind: string
  message_id: number | null
  path: string
  label: string
}

export type JobScheduledTask = {
  id: number
  name: string
  scheduled_task_path: string
}

export type JobOriginChat = {
  chat_session_id: number
  message_id: number
}

export type JobTag = {
  id: number
  name: string
  color: string
}

export type JobDependencyTarget = {
  id: number
  kind: string
  state: string
  summary_state: string
  repository_slug: string
  issue_number: number | null
  issue_title: string | null
  branch_name: string | null
  pr_number: number | null
  job_path: string
}

export type JobDependency = {
  id: number
  source: string
  manual: boolean
  pending: boolean
  succeeded: boolean
  unresolved_slug: string | null
  depends_on_job: JobDependencyTarget | null
}

export type JobDependent = {
  id: number
  source: string
  job: JobDependencyTarget
}

export type JobOption = {
  label: string
  value: string
}

export type JobAttachment = {
  id: number
  kind: string
  attachment_type: string
  title: string | null
  filename: string | null
  content_type: string | null
  byte_size: number | null
  google_doc_url: string | null
  uploaded_file: boolean
  file_path: string | null
  created_at: string | null
  app_delete_path: string
}

export type JobSummary = {
  run_id: number
  text: string
  finished_at: string | null
}

export type JobTestPlan = {
  workflow_id: number
  steps: string[]
  notes: string | null
}

export type JobAdversarialReviewIteration = {
  iteration: number
  critique: string
  verdict: "needs_work" | "approved"
}

export type LandingQueueBlockerJob = {
  id: number
  title: string
  job_path: string
  state: string
  pr_number: number | null
  pr_path: string | null
  epic_id?: number | null
  epic_title?: string | null
}

export type LandingQueueDependencyEdge = {
  from_job_id: number
  to_job_id: number
}

export type JobLandingQueueEntry = {
  position: number
  blocked_reason: string | null
  waiting_for_jobs: Array<{
    id: number
    label: string
    title: string
    job_path: string
  }>
  blocker_jobs?: LandingQueueBlockerJob[]
  dependency_edges?: LandingQueueDependencyEdge[]
}

export type JobWorkflowsPagination = {
  page: number
  per_page: number
  total_workflows: number
  total_pages: number
  first_item: number
  last_item: number
  previous_path: string | null
  next_path: string | null
}

export type JobWorkflow = {
  id: number
  slug: string
  path: string
  trigger_kind: string
  agent_provider: string | null
  state: string
  failure_count: number
  artifacts: Record<string, unknown> | null
  cleaned_up_at: string | null
  retry_available: boolean
  started_at: string | null
  finished_at: string | null
  created_at: string | null
  updated_at: string | null
  app_retry_step_path: string
  app_push_commits_path: string
  app_force_push_branch_path: string
  app_discard_branch_output_path: string
  failure_classification?: RunFailureClassification | null
  steps: JobStep[]
}

export type JobStep = {
  id: number
  kind: string
  display_name: string
  display_status: string | null
  position: number
  iteration: number | null
  loop_id: string | null
  state: string
  started_at: string | null
  finished_at: string | null
  created_at: string | null
  updated_at: string | null
  details: unknown
  latest: boolean
  runs: JobRun[]
}

export type JobRun = {
  id: number
  state: string
  trigger_kind: string
  agent_provider: string | null
  agent_outcome: string | null
  agent_turns: number | null
  agent_pr_title: string | null
  agent_summary: string | null
  parent_session_id: string | null
  head_sha: string | null
  iteration: number | null
  started_at: string | null
  last_heartbeat_at: string | null
  finished_at: string | null
  created_at: string | null
  updated_at: string | null
  cost_usd: number | null
  input_tokens: number | null
  output_tokens: number | null
  agent_diff_present: boolean
  agent_diff_bytes: number
  job_log_count: number
  rate_limited: boolean
  failure_classification?: RunFailureClassification | null
  run_diagnostic: { id: number; present: boolean; created_at: string | null; error_class?: string; error_message?: string } | null
  health_snapshots: Array<{ id: number; health_status: string | null; hint: string | null; run_state: string | null; last_log_preview: string | null; created_at: string | null }>
  agent_session: { session_id: string; provider: string | null; transcript_pruned: boolean; transcript_bytes: number | null; transcript_lines: number | null } | null
  can_stop: boolean
  can_diagnose: boolean
  can_resume: boolean
  app_artifacts_path: string
  app_stop_path: string
  app_diagnose_path: string
  app_resume_path: string
  app_grade_log_path: string | null
}

export type RunFailureClassification = {
  id: number
  classification: string
  confidence: number | null
  retryable: boolean
  reason: string | null
  diagnostic_summary: string | null
  classifier_inputs?: Record<string, unknown> | null
  classified_at: string | null
}

export type JobActions = {
  can_start: boolean
  can_poll_feedback: boolean
  can_rebase: boolean
  can_check_mergeability: boolean
  can_retry: boolean
  can_retry_from_failed_step: boolean
  retry_failed_step_action?: JobRetryAction | null
  retry_implementation_action?: JobRetryAction | null
  can_restart: boolean
  can_cancel: boolean
  can_approve: boolean
  can_unapprove: boolean
  can_reopen: boolean
  can_mark_valid: boolean
  can_open_in_local_mode: boolean
  can_cancel_local_mode: boolean
  linked_chat_id: number | null
  can_claim: boolean
  can_unclaim: boolean
  can_override_dependencies: boolean
  can_view_timeline: boolean
  can_manage_tags: boolean
  can_open_in_coding_mode: boolean
  feedback_agent_options: string[]
  rebase_agent_options: string[]
  retry_agent_options: string[]
}

export type JobRetryAction = {
  key: string
  label: string
  path: string
  workflow_id?: number
  step_id?: number
  step_kind?: string
  step_label?: string
}

export type JobPaths = {
  job_path: string
  source_path: string
  app_detail_path: string
  app_source_path: string
  app_timeline_path: string
  app_start_path: string
  app_run_again_path: string
  app_restart_path: string
  app_cancel_path: string
  app_approve_path: string
  app_unapprove_path: string
  app_reopen_path: string
  app_poll_feedback_path: string
  app_rebase_path: string
  app_check_mergeability_path: string
  app_resume_path: string
  app_tags_path: string
  app_claim_path: string
  app_dependencies_path: string
  app_dependency_override_path: string
  app_stack_base_path: string
  app_mark_valid_path: string
  app_attachments_path: string
  app_pin_path: string
  app_pending_feedback_path?: string
  app_open_in_coding_mode_path: string
  app_open_in_local_mode_path: string
  app_cancel_local_mode_path: string
}

export type JobDetailPayload = {
  message?: string | null
  job: JobRecord
  repository: JobRepository
  epic: JobEpic | null
  origin_chat: JobOriginChat | null
  pinned: boolean
  tags: JobTag[]
  tag_options: JobTag[]
  dependencies: JobDependency[]
  dependents: JobDependent[]
  unsatisfied_dependencies: JobDependency[]
  dependency_target_options: JobOption[]
  attachments: JobAttachment[]
  summary: JobSummary | null
  test_plan: JobTestPlan | null
  pending_feedback?: PendingFeedbackComment[]
  landing_queue_entry: JobLandingQueueEntry | null
  workflows: JobWorkflow[]
  workflows_pagination: JobWorkflowsPagination
  feature_flags?: Record<string, boolean>
  actions: JobActions
  paths: JobPaths
}

export type JobTimelinePayload = {
  job_id: number
  events: Array<{
    at: string | null
    kind: string
    source: string
    transition_source: string | null
    title: string
    detail: string | null
    ref: Record<string, unknown> | string | null
    ref_label: string | null
    workflow_path: string | null
  }>
}

export type JobSourcePayload = {
  job_id: number
  repository: Pick<JobRepository, "id" | "slug" | "default_branch" | "repository_path">
  branch_name: string | null
  default_ref: string
  selected_ref: string
  selected_path: string | null
  merge_base_sha: string | null
  branch_commits: Array<{ sha: string; short_sha: string; message: string; date: string | null }>
  tree_items: Array<{ path: string; name: string; size: number; language: string }>
  tree_truncated: boolean
  file: { path: string; name: string; size: number; language: string; content: string } | null
  source_error: string | null
  file_error: string | null
  paths: Pick<JobPaths, "job_path" | "source_path" | "app_source_path">
}

export type JobSourceDiffPayload = {
  job_id: number
  base_ref: string | null
  head_ref: string | null
  merge_base_sha: string | null
  default_ref: string
  branch_commits: Array<{ sha: string; short_sha: string; message: string; date: string | null }>
  files: Array<{ path: string; status: string; additions: number; deletions: number; patch: string | null }>
  truncated: boolean
  diff_error: string | null
}

export type JobCommandPayload = {
  message?: string | null
  redirect_to?: string
}

export type JobGradeLogPayload = {
  job_id: number
  run_id: number
  name: string
  contents: string
}

export type JobRunArtifactsPayload = {
  job_id: number
  run_id: number
  agent_diff: string | null
  agent_diff_bytes: number
  logs_count: number
  logs: Array<{
    id: number
    sequence: number
    kind: string | null
    chunk: string
    created_at: string | null
  }>
}

export function fetchJobDetail(id: string, search = "") {
  return getJson<JobDetailPayload>(`/api/v1/app/jobs/${id}${search}`)
}

export function fetchJobTimeline(id: string) {
  return getJson<JobTimelinePayload>(`/api/v1/app/jobs/${id}/timeline`)
}

export function fetchJobSource(id: string, search = "") {
  return getJson<JobSourcePayload>(`/api/v1/app/jobs/${id}/source${search}`)
}

export function fetchJobSourceDiff(id: string, search = "") {
  return getJson<JobSourceDiffPayload>(`/api/v1/app/jobs/${id}/source_diff${search}`)
}

export function fetchJobGradeLog(path: string) {
  return getJson<JobGradeLogPayload>(path)
}

export function fetchJobRunArtifacts(path: string) {
  return getJson<JobRunArtifactsPayload>(path)
}

export type CoverageArtifact = {
  summary?: { lines_pct: number | null; branches_pct: number | null; functions_pct: number | null }
  files?: Record<string, { lines_pct: number | null; branches_pct: number | null }>
  diff_annotations?: Record<string, Record<string, "covered" | "uncovered" | "not_executable">>
  pr_delta?: { covered: number; total: number; pct: number | null; uncovered_files: string[] }
  threshold_miss?: boolean
  threshold_miss_details?: { lines_pct: number | null; threshold_lines: number | null; pr_delta_pct: number | null; threshold_pr_lines: number | null }
  coverage_unavailable?: boolean
  sources_status?: Array<{ artifact: string; found: boolean; lines_pct: number | null }>
  hit_map_attached?: boolean
}

export type WorkflowCoverageHitMapPayload = {
  hit_map_attached: boolean
  file: string
  lines: Record<string, number>
}

export function fetchWorkflowCoverageHitMap(workflowId: number, file: string) {
  const params = new URLSearchParams({ file })
  return getJson<WorkflowCoverageHitMapPayload>(`/api/v1/app/workflows/${workflowId}/coverage_hit_map?${params}`)
}

export function postJobCommand(path: string, body?: unknown) {
  return postJson<JobCommandPayload>(path, body)
}

export function patchJobCommand(path: string, body?: unknown) {
  return patchJson<JobCommandPayload>(path, body)
}

export function deleteJobCommand(path: string) {
  return deleteJson<JobCommandPayload>(path)
}

export async function submitJobFeedback(jobId: number, body: string): Promise<void> {
  await postJson(`/api/v1/app/jobs/${jobId}/chat_feedback`, { body })
}

export type PendingFeedbackActionPayload = {
  message: string
  workflow?: { id: number; state: string }
}

export function applyPendingFeedback(jobId: number, commentId: number) {
  return postJson<PendingFeedbackActionPayload>(`/api/v1/app/jobs/${jobId}/pending_feedback/${commentId}/apply`)
}

export function ignorePendingFeedback(jobId: number, commentId: number) {
  return postJson<JobDetailPayload>(`/api/v1/app/jobs/${jobId}/pending_feedback/${commentId}/ignore`)
}

export function replacePendingFeedback(jobId: number, commentId: number, body: string) {
  return postJson<PendingFeedbackActionPayload>(`/api/v1/app/jobs/${jobId}/pending_feedback/${commentId}/replace`, { body })
}

export function createJobAttachments(path: string, values: { files: File[]; googleDocUrl: string }) {
  const formData = new FormData()
  values.files.forEach((file) => formData.append("job_attachment[files][]", file))
  formData.append("job_attachment[google_doc_url]", values.googleDocUrl)

  return postForm<JobCommandPayload>(path, formData)
}
