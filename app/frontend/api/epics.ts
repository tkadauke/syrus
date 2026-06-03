import { getJson, patchJson, postJson } from "./client"

export type EpicRepositoryOption = {
  id: number
  slug: string
}

export type EpicFormRecord = {
  id: number | null
  title: string
  description: string
  owner_user_id: number | null
  owner_status: "mine" | "other_owned" | "unclaimed"
  owner_user: EpicOwnerUser | null
  repository_id: number | null
  github_issue_url: string
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
}

export type EpicDetailSummary = {
  done_jobs_count: number
  total_jobs_count: number
  dependency_edge_count: number
  blocked: boolean
}

export type EpicStateTransition = {
  label: string
  target_state: string
  confirm: string | null
}

export type EpicGraph = {
  empty: boolean
  definition: string
  node_count: number
  epic_dependency_count: number
  job_blocker_count: number
  initially_open: boolean
}

export type EpicDetailJob = {
  id: number
  label: string
  title: string
  path: string
  state: string
  owner_user_id: number | null
  owner_user: EpicOwnerUser | null
  repository_slug: string
}

export type EpicDetailPayload = {
  message?: string | null
  epic: EpicDetailRecord
  summary: EpicDetailSummary
  state_transitions: EpicStateTransition[]
  graph: EpicGraph
  jobs: EpicDetailJob[]
  paths: {
    dashboard_epics_path: string
    edit_epic_path: string
    app_state_path: string
    app_archive_path: string
    app_claim_path: string
    app_unclaim_path: string
    app_reassign_path: string
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

export function createEpic(values: EpicInput) {
  return postJson<EpicSavedPayload>("/api/v1/app/epics", { epic: values })
}

export function updateEpic(id: number, values: EpicInput) {
  return patchJson<EpicSavedPayload>(`/api/v1/app/epics/${id}`, { epic: values })
}

export function updateEpicState(path: string, targetState: string) {
  return patchJson<EpicDetailPayload>(path, { target_state: targetState })
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
