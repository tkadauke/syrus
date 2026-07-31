import { deleteJson, getJson, patchJson, postJson } from "./client"
import type { DashboardGraphEdge, DashboardGraphNode } from "./dashboard"
import type { ProviderAvailability } from "./providerAvailability"
import type { RepositoryEpicDependencyPolicy } from "./repositories"

export type EpicRepositoryOption = {
  id: number
  slug: string
  epic_dependency_policy: RepositoryEpicDependencyPolicy
}

export type EpicSearchOption = {
  value: string | number
  label: string
}

export type EpicReconciliationMode = "pr" | "feedback" | "none" | null
export type EpicDependencyPolicy = "linear" | "nonlinear"

export type EpicFormRecord = {
  id: number | null
  title: string
  description: string
  owner_user_id: number | null
  owner_status: "mine" | "other_owned" | "unclaimed"
  owner_user: EpicOwnerUser | null
  repository_id: number | null
  github_issue_url: string
  reconciliation_mode: EpicReconciliationMode
  epic_dependency_policy: EpicDependencyPolicy
  resolved_epic_dependency_policy: "linear" | "nonlinear" | null
  epic_path: string | null
}

export type EpicOwnerUser = {
  id: number
  email_address: string
}

export type EpicFormPayload = {
  epic: EpicFormRecord
  repositories: EpicRepositoryOption[]
  dashboard_epics_path: string
}

export type EpicInput = {
  title: string
  description: string
  repository_id: string
  github_issue_url: string
  reconciliation_mode: EpicReconciliationMode
  epic_dependency_policy: EpicDependencyPolicy
}

export type EpicSavedPayload = {
  message: string
  redirect_to: string
  epic: EpicFormRecord
}

export type EpicDetailRepository = {
  id: number
  slug: string
  repository_path: string
  epic_dependency_policy: RepositoryEpicDependencyPolicy
}

export type EpicOwner = {
  id: number
  email_address: string
}

export type EpicDetailRecord = {
  id: number
  number: number
  display_number: string
  title: string
  description: string
  state: string
  stuck: boolean
  startable: boolean
  start_blocked_on: string[]
  owner: EpicOwner | null
  owned_by_current_user: boolean
  claimable: boolean
  claimed_at: string | null
  github_issue_url: string
  updated_at: string
  archived: boolean
  jobs_count: number
  epic_path: string
  owner_user_id: number | null
  owner_status: "mine" | "other_owned" | "unclaimed"
  owner_user: EpicOwnerUser | null
  repository: EpicDetailRepository
  max_commits_behind_base: number | null
  furthest_behind_job_id: number | null
  furthest_behind_job_path: string | null
  epic_dependency_policy: EpicDependencyPolicy
  resolved_epic_dependency_policy: "linear" | "nonlinear"
}

export type EpicDetailSummary = {
  done_jobs_count: number
  total_jobs_count: number
  dependency_edge_count: number
  blocked: boolean
  blocked_reason: string | null
}

export type MergeTrainReconciliationStatus = {
  step_id: number
  state: string
  result: "no_changes" | "committed" | "failed" | "running" | null
  run_id: number | null
  head_sha: string | null
  diff_bytes: number
}

export type MergeTrainStatus = {
  id: number
  state: string
  phase: "assembling" | "reconciling" | "grading" | "landing" | "failed" | "landed" | string
  branch: string | null
  member_count: number
  workflow_id: number | null
  workflow_state: string | null
  current_step_kind: string | null
  current_step_label: string | null
  reconciliation: MergeTrainReconciliationStatus | null
  failure_reason: string | null
}

export type EpicStateTransition = {
  label: string
  target_state: string
  confirm: string | null
}

export type EpicGraph = {
  empty: boolean
  node_count: number
  epic_dependency_count: number
  job_blocker_count: number
  initially_open: boolean
  nodes: DashboardGraphNode[]
  edges: DashboardGraphEdge[]
}

export type EpicDependencyRecord = {
  epic_id: number
  title: string
  state: string
  url: string
}

export type EpicDetailJob = {
  id: number
  slug: string
  label: string
  title: string
  path: string
  state: string
  agent_provider?: string | null
  provider_availability?: ProviderAvailability
  pr_number: number | null
  pr_url: string | null
  owner_user_id: number | null
  owner_user: EpicOwnerUser | null
  repository_slug: string
}

export type EpicVersionRecord = {
  id: number
  created_at: string
  actor: EpicOwnerUser | { email_address: string }
  title_before: string | null
  title_after: string | null
  description_before: string | null
  description_after: string | null
}

export type EpicOriginChat = {
  chat_session_id: number
  message_id: number
}

export type EpicDetailPayload = {
  message?: string | null
  origin_chat?: EpicOriginChat | null
  merge_train_status?: MergeTrainStatus | null
  epic: EpicDetailRecord
  summary: EpicDetailSummary
  state_transitions: EpicStateTransition[]
  graph: EpicGraph
  dependencies: EpicDependencyRecord[]
  dependents: EpicDependencyRecord[]
  jobs: EpicDetailJob[]
  versions?: EpicVersionRecord[]
  paths: {
    dashboard_epics_path: string
    edit_epic_path: string
    app_state_path: string
    app_start_path: string
    app_archive_path: string
    app_claim_path: string
    app_unclaim_path: string
    app_reassign_path: string
    app_dependencies_path: string
  }
}

export function fetchNewEpicForm() {
  return getJson<EpicFormPayload>("/api/v1/app/epics/new")
}

export function fetchEditEpicForm(id: string) {
  return getJson<EpicFormPayload>(`/api/v1/app/epics/${id}/edit`)
}

export function fetchEpicDetail(id: string) {
  return getJson<EpicDetailPayload>(`/api/v1/app/epics/${id}`)
}

export function searchEpicOptions(query: string, options: { signal?: AbortSignal } = {}) {
  const params = new URLSearchParams({ field: "epic_id", q: query })
  return getJson<{ options?: EpicSearchOption[] }>(`/api/v1/app/filters/fk_options?${params}`, options)
    .then((payload) => payload.options || [])
}

export function createEpic(values: EpicInput, options: { start?: boolean } = {}) {
  return postJson<EpicSavedPayload>("/api/v1/app/epics", options.start ? { epic: values, start: true } : { epic: values })
}

export function updateEpic(id: number, values: EpicInput) {
  return patchJson<EpicSavedPayload>(`/api/v1/app/epics/${id}`, { epic: values })
}

export function updateEpicState(path: string, targetState: string) {
  return patchJson<EpicDetailPayload>(path, { target_state: targetState })
}

// Move an Epic straight to In Progress (override so a freshly-confirmed Epic
// in backlog/ready starts in one click). Used by the chat "Start" action.
export function startEpic(path: string) {
  return patchJson<EpicDetailPayload>(path, { target_state: "in_progress", override: true })
}

// Explicit "Start implementing" action (POST /api/v1/app/epics/:id/start):
// moves the Epic to In progress and dispatches its ready child Jobs.
export function startEpicImplementing(path: string) {
  return postJson<EpicDetailPayload>(path, {})
}

export function archiveEpic(path: string) {
  return patchJson<EpicDetailPayload>(path)
}

export function claimEpic(path: string) {
  return patchJson<EpicDetailPayload>(path)
}

export function unclaimEpic(path: string) {
  return patchJson<EpicDetailPayload>(path)
}

export function addEpicDependency(path: string, dependsOnEpicId: number) {
  return postJson<EpicDetailPayload>(path, { depends_on_epic_id: dependsOnEpicId })
}

export function removeEpicDependency(path: string, dependsOnEpicId: number) {
  return deleteJson<EpicDetailPayload>(`${path}/${dependsOnEpicId}`)
}
