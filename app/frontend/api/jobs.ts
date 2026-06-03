import { deleteJson, getJson, patchJson, postForm, postJson } from "./client"

export type JobRepository = {
  id: number
  slug: string
  owner: string
  name: string
  default_branch: string
  repository_path: string
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
  issue_title: string | null
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
  approved_at: string | null
  approved_via: string | null
  total_cost_usd: number | null
  owner_user_id: number | null
  owner_user: JobOwnerUser | null
  billed_runs_count: number
  workflows_count: number
  runs_count: number
  any_active_run: boolean
  prepare_skipped: boolean
  prepare_skip_reason: string | null
  created_at: string | null
  updated_at: string | null
  started_at: string | null
  finished_at: string | null
}

export type JobOwnerUser = {
  id: number
  email_address: string
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

export type JobLandingQueueEntry = {
  position: number
  blocked_reason: string | null
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
  trigger_kind: string
  agent_provider: string | null
  state: string
  failure_count: number
  artifacts: Record<string, unknown>
  cleaned_up_at: string | null
  retry_available: boolean
  started_at: string | null
  finished_at: string | null
  created_at: string | null
  updated_at: string | null
  app_retry_step_path: string
  app_push_commits_path: string
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

export type JobActions = {
  can_start: boolean
  can_poll_feedback: boolean
  can_rebase: boolean
  can_check_mergeability: boolean
  can_retry: boolean
  can_retry_from_failed_step: boolean
  can_restart: boolean
  can_cancel: boolean
  can_approve: boolean
  can_unapprove: boolean
  can_reopen: boolean
  can_mark_valid: boolean
  can_override_dependencies: boolean
  can_view_timeline: boolean
  feedback_agent_options: string[]
  rebase_agent_options: string[]
  retry_agent_options: string[]
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
  app_dependencies_path: string
  app_dependency_override_path: string
  app_stack_base_path: string
  app_mark_valid_path: string
  app_attachments_path: string
  app_pin_path: string
}

export type JobDetailPayload = {
  message?: string | null
  job: JobRecord
  repository: JobRepository
  pinned: boolean
  tags: JobTag[]
  tag_options: JobTag[]
  dependencies: JobDependency[]
  dependents: JobDependent[]
  unsatisfied_dependencies: JobDependency[]
  dependency_target_options: JobOption[]
  attachments: JobAttachment[]
  summary: JobSummary | null
  landing_queue_entry: JobLandingQueueEntry | null
  workflows: JobWorkflow[]
  workflows_pagination: JobWorkflowsPagination
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
    ref: string | null
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

export function fetchJobGradeLog(path: string) {
  return getJson<JobGradeLogPayload>(path)
}

export function fetchJobRunArtifacts(path: string) {
  return getJson<JobRunArtifactsPayload>(path)
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

export function createJobAttachments(path: string, values: { files: File[]; googleDocUrl: string }) {
  const formData = new FormData()
  values.files.forEach((file) => formData.append("job_attachment[files][]", file))
  formData.append("job_attachment[google_doc_url]", values.googleDocUrl)

  return postForm<JobCommandPayload>(path, formData)
}
