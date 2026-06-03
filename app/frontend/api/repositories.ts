import { deleteJson, getJson, patchJson, postJson } from "./client"
import type { SetupStatusPayload } from "./setup"

export type RepositoryRow = {
  id: number
  slug: string
  owner: string
  name: string
  owner_user: RepositoryOwnerUser
  default_branch: string
  upstream_owner: string | null
  upstream_name: string | null
  upstream_default_branch: string | null
  upstream_slug: string | null
  trigger_label: string
  polling_enabled: boolean
  archived: boolean
  archived_at: string | null
  agent_provider: string | null
  agent_provider_label: string
  last_poll_status: string | null
  last_poll_started_at: string | null
  last_poll_error: string | null
  repository_path: string
  edit_repository_path: string
}

export type RepositoriesPayload = {
  active_repositories: RepositoryRow[]
  archived_repositories: RepositoryRow[]
  new_repository_path: string
  setup?: SetupStatusPayload
  message?: string | null
}

export type RepositoryFormRecord = {
  id: number | null
  owner: string
  name: string
  slug: string | null
  default_branch: string
  upstream_owner: string
  upstream_name: string
  upstream_default_branch: string
  trigger_label: string
  polling_enabled: boolean
  prepare_enabled: boolean
  pr_cost_footer_enabled: boolean
  auto_merge_enabled: boolean
  agent_provider: string
  auto_approve_mode: string
  github_owner_id: number | null
  github_repository_id: number | null
  repository_path: string | null
}

export type RepositoryProviderOption = {
  value: string
  label: string
}

export type RepositoryAutoApproveMode = {
  value: string
  label: string
  preview: string
}

export type RepositoryFormPayload = {
  repository: RepositoryFormRecord
  configured_agent_providers: RepositoryProviderOption[]
  user_agent_provider_label: string
  auto_approve_modes: RepositoryAutoApproveMode[]
  repositories_path: string
}

export type RepositoryInput = {
  owner: string
  name: string
  default_branch: string
  upstream_owner: string
  upstream_name: string
  upstream_default_branch: string
  trigger_label: string
  polling_enabled: boolean
  prepare_enabled: boolean
  pr_cost_footer_enabled: boolean
  auto_merge_enabled: boolean
  agent_provider: string
  auto_approve_mode: string
  github_owner_id: string
  github_repository_id: string
}

export type RepositorySavedPayload = {
  message: string
  redirect_to: string
  repository: RepositoryRow
}

export type GitHubOwnersPayload = {
  user?: string
  orgs?: string[]
  error?: string
}

export type GitHubRepositoryOption = {
  name: string
  github_repository_id: number | null
  github_owner_id: number | null
}

export type GitHubRepositoriesPayload = {
  repos?: Array<string | GitHubRepositoryOption>
  error?: string
}

export type GitHubBranchesPayload = {
  branches?: string[]
  default_branch?: string
  error?: string
}

export type RepositoryDetailPayload = {
  message?: string | null
  repository: RepositoryDetailRecord
  tabs: RepositoryTab[]
  counts: {
    running: number
    queued: number
    failed_7d: number
  }
  retry_failed_jobs: {
    count: number
    agent_provider: string
    agent_provider_label: string
  }
  credential_status: {
    mode: "app" | "pat"
    label: string
    installation_account: string | null
    github_app_registered: boolean
    install_url: string | null
    register_path: string | null
    previous_installation_removed: boolean
    missing_github_ids: boolean
  }
  notes: RepositoryNote[]
  jobs: RepositoryDetailJob[]
  pagination: {
    page: number
    per_page: number
    total_jobs: number
    total_pages: number
    first_item: number
    last_item: number
    previous_path: string | null
    next_path: string | null
  }
  paths: {
    new_job_path: string
    edit_repository_path: string
    app_poll_repository_path: string
    app_archive_repository_path: string
    app_retry_failed_jobs_repository_path: string
    app_repository_notes_path: string
    repositories_path: string
    repository_documents_path: string
    repository_scheduled_tasks_path: string
  }
}

export type RepositoryDetailRecord = {
  id: number
  slug: string
  owner: string
  name: string
  default_branch: string
  upstream_owner: string | null
  upstream_name: string | null
  upstream_default_branch: string | null
  upstream_slug: string | null
  trigger_label: string
  polling_enabled: boolean
  archived: boolean
  agent_provider: string | null
  agent_provider_label: string | null
  effective_agent_provider: string
  effective_agent_provider_label: string
  github_url: string
  created_at: string
  owner_user: RepositoryOwnerUser
  github_rate_limit: {
    remaining: number
    limit: number
    resource: string
    observed_at: string
  } | null
}

export type RepositoryOwnerUser = {
  id: number
  display_name: string
  email_address: string
  admin: boolean
  profile_path?: string
}

export type RepositoryTab = {
  key: string
  label: string
  path: string
}

export type RepositoryNote = {
  id: number
  body: string
  author: string
  created_at: string
  app_delete_path: string
}

export type RepositoryDetailJob = {
  id: number
  state: string
  priority: string
  issue_number: number | null
  issue_title: string
  job_path: string
  source: {
    label: string
    path: string | null
    external: boolean
  }
  pr_number: number | null
  pr_url: string | null
  external_pr_number: number | null
  external_pr_url: string | null
  current_step_caption: string | null
  runs_count: number
  updated_at: string
}

export type RepositoryIssuesPayload = {
  message?: string | null
  error_message?: string | null
  repository: RepositoryDetailRecord
  tabs: RepositoryTab[]
  state: "open" | "closed"
  issue_count: number
  issues: RepositoryIssue[]
  state_paths: {
    open: string
    closed: string
  }
  paths: {
    github_issues_path: string
    app_comment_issue_path: string
    app_close_issue_path: string
    app_delegate_issue_path: string
    app_bulk_issues_path: string
  }
}

export type RepositoryIssue = {
  number: number
  title: string
  state: string
  html_url: string
  body_excerpt: string
  user_login: string | null
  created_at: string | null
  labels: Array<{
    name: string
    color: string
  }>
  delegated: boolean
}

export function fetchRepositories() {
  return getJson<RepositoriesPayload>("/api/v1/app/repositories")
}

export function fetchRepositoryDetail(id: string, search = "") {
  return getJson<RepositoryDetailPayload>(`/api/v1/app/repositories/${id}${search}`)
}

export function fetchRepositoryIssues(id: string, state: string) {
  const params = new URLSearchParams({ state })
  return getJson<RepositoryIssuesPayload>(`/api/v1/app/repositories/${id}/issues?${params}`)
}

export function commentRepositoryIssue(path: string, values: { issueNumber: number; commentBody: string; state: string }) {
  return postJson<RepositoryIssuesPayload>(path, {
    issue_number: values.issueNumber,
    comment_body: values.commentBody,
    state: values.state
  })
}

export function closeRepositoryIssue(path: string, values: { issueNumber: number; state: string }) {
  return postJson<RepositoryIssuesPayload>(path, {
    issue_number: values.issueNumber,
    state: values.state
  })
}

export function delegateRepositoryIssue(path: string, values: { issueNumber: number; state: string }) {
  return postJson<RepositoryIssuesPayload>(path, {
    issue_number: values.issueNumber,
    state: values.state
  })
}

export function bulkRepositoryIssues(path: string, values: { issueNumbers: number[]; bulkAction: "close" | "delegate"; state: string }) {
  return postJson<RepositoryIssuesPayload>(path, {
    issue_numbers: values.issueNumbers,
    bulk_action: values.bulkAction,
    state: values.state
  })
}

export function createRepositoryNote(path: string, body: string) {
  return postJson<RepositoryDetailPayload>(path, { repository_note: { body } })
}

export function deleteRepositoryNote(path: string) {
  return deleteJson<RepositoryDetailPayload>(path)
}

export function pollRepositoryDetail(path: string, page: number) {
  return postJson<RepositoryDetailPayload>(path, { return_to: "detail", page })
}

export function retryFailedRepositoryJobs(path: string, page: number) {
  return postJson<RepositoryDetailPayload>(path, { page })
}

export function archiveRepositoryFromPath(path: string) {
  return postJson<RepositoriesPayload>(path)
}

export function fetchNewRepositoryForm() {
  return getJson<RepositoryFormPayload>("/api/v1/app/repositories/new")
}

export function fetchEditRepositoryForm(id: string) {
  return getJson<RepositoryFormPayload>(`/api/v1/app/repositories/${id}/edit`)
}

export function fetchRepositoryOwners() {
  return getJson<GitHubOwnersPayload>("/api/v1/app/repositories/owners")
}

export function fetchRepositoryOptions(owner: string, ownerType: string) {
  const params = new URLSearchParams({ owner, owner_type: ownerType })
  return getJson<GitHubRepositoriesPayload>(`/api/v1/app/repositories/repos?${params}`)
}

export function fetchRepositoryBranches(owner: string, name: string) {
  const params = new URLSearchParams({ owner, name })
  return getJson<GitHubBranchesPayload>(`/api/v1/app/repositories/branches?${params}`)
}

export function createRepository(values: RepositoryInput) {
  return postJson<RepositorySavedPayload>("/api/v1/app/repositories", { repository: values })
}

export function updateRepository(id: number, values: RepositoryInput) {
  return patchJson<RepositorySavedPayload>(`/api/v1/app/repositories/${id}`, { repository: values })
}

export function pollRepository(id: number) {
  return postJson<RepositoriesPayload>(`/api/v1/app/repositories/${id}/poll`)
}

export function archiveRepository(id: number) {
  return postJson<RepositoriesPayload>(`/api/v1/app/repositories/${id}/archive`)
}

export function unarchiveRepository(id: number) {
  return postJson<RepositoriesPayload>(`/api/v1/app/repositories/${id}/unarchive`)
}
