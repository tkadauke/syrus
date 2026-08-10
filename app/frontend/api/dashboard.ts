import { getJson, getJsonWithMeta, patchJson, postJson } from "./client"
import type { JsonResponseMeta } from "./client"
import type { JobRetryState, LandingQueueBlockerJob, LandingQueueDependencyEdge } from "./jobs"
import type { BlockedReason } from "../lib/translateBlockedReason"
import type { ProviderAvailability } from "./providerAvailability"
import type { StartBlockedDetails } from "../types/startBlocked"

import type { SetupStatusPayload } from "./setup"

export type DashboardSubject = "job" | "epic" | "workflow"

export type DashboardRepository = {
  id: number
  slug: string
  repository_path: string
}

export type DashboardHealthBlockedRepository = {
  id: number
  slug: string
  main_health: string
  ci_health: string
  grader_health: string
  landing_paused: boolean
  repository_path: string
  repair_path: string
  main_branch_repair: DashboardMainBranchRepairStatus
}

export type DashboardRepairJob = {
  id: number
  slug: string
  state: string
  title: string
  job_path: string
}

export type DashboardMainBranchRepairStatus = {
  enabled: boolean
  failed_open_jobs_count: number
  max_open_failed_jobs: number
  blocked_reason: string | null
  can_request: boolean
  can_spawn: boolean
  blocking_job: DashboardRepairJob | null
  failed_jobs: DashboardRepairJob[]
}

export type DashboardOwner = {
  id: number
  email_address: string
  display_name: string
}

export type DashboardOwnerUser = {
  id: number
  name: string | null
  email_address: string
}

export type DashboardOwnerBadge = {
  label: string
  kind: "claimable" | "other_user"
}

export type DashboardTag = {
  id: number
  name: string
  color: string
}

export type DashboardJobEpic = {
  id: number
  number: number
  display_number: string
  path: string
  jobs_count: number
  landed_jobs_count: number
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

export type DashboardClaimOwner = {
  id: number
  display_name: string
  profile_path: string
}

export type DashboardDeploymentStage = {
  name: string
  label: string
  reached_at: string | null
}

export type DashboardLandingQueueEntry = {
  key: string
  position: number
  job_ids: number[]
  blocker_jobs: LandingQueueBlockerJob[]
  dependency_edges: LandingQueueDependencyEdge[]
}

export type DashboardJobItem = {
  type: "job"
  id: number
  kind: string
  title: string
  title_pending?: boolean
  state: string
  summary_state: string
  validity: string
  priority: string
  agent_provider: string | null
  provider_availability?: ProviderAvailability
  total_cost_usd: number | null
  issue_number: number | null
  issue_url: string | null
  branch_name: string | null
  pr_number: number | null
  active_workflow_trigger_kind: string | null
  latest_workflow_id: number | null
  latest_workflow_trigger_kind: string | null
  pr_url: string | null
  latest_workflow_state: string
  latest_deployment_stage?: DashboardDeploymentStage | null
  landing_queue_position: number | null
  landing_queue_blocked_reason: BlockedReason | string | null
  landing_queue_wait_reason: BlockedReason | string | null
  landing_queue_entry_key: string | null
  blocked_reason: BlockedReason | null
  retry_state?: JobRetryState
  created_at: string | null
  updated_at: string | null
  started_at: string | null
  finished_at: string | null
  approved_at: string | null
  owner_user_id: number | null
  owner_user: DashboardOwnerUser | null
  claimed_at: string | null
  claimed_by_user: DashboardClaimOwner | null
  claimed_by_current_user: boolean
  dependencies_overridden_at: string | null
  last_feedback_addressed_at: string | null
  last_seen_comment_at: string | null
  pr_mergeable_checked_at: string | null
  commits_behind_base: number | null
  workflows_count: number
  repository: DashboardRepository
  epic: DashboardJobEpic | null
  owner_badge: DashboardOwnerBadge | null
  tags: DashboardTag[]
  source_chat: JobSourceChat | null
  needs_attention: boolean
  needs_attention_reason: string | null
  start_blocked_reason: string | null
  start_blocked_at: string | null
  start_blocked_next_check_at: string | null
  start_blocked_count: number | null
  start_blocked_details: StartBlockedDetails | null
  manual_paused?: boolean
  manual_paused_at?: string | null
  manual_paused_by_user?: DashboardOwnerUser | null
  paths: {
    job_path: string
    source_path: string
    app_pause_path?: string
    app_unpause_path?: string
  }
}

export type DashboardEpicItem = {
  type: "epic"
  id: number
  number: number
  display_number: string
  title: string
  description: string
  state: string
  simple_status?: string
  stuck: boolean
  all_jobs_closed: boolean
  owner: DashboardOwner | null
  owned_by_current_user: boolean
  claimable: boolean
  owner_badge: DashboardOwnerBadge | null
  claimed_at: string | null
  auto_approve_mode: string
  owner_user_id: number | null
  owner_status: "mine" | "other_owned" | "unclaimed"
  jobs_count: number
  landed_jobs_count: number
  job_state_counts: Record<string, number>
  max_commits_behind_base: number | null
  created_at: string | null
  updated_at: string | null
  done_at: string | null
  archived_at: string | null
  repository: DashboardRepository
  paths: {
    epic_path: string
    edit_epic_path: string
    app_state_path: string
    app_claim_path: string
    app_unclaim_path: string
  }
}

export type DashboardWorkflowItem = {
  type: "workflow"
  id: number
  slug: string
  path: string
  state: string
  trigger_kind: string
  agent_provider: string
  created_at: string | null
  updated_at: string | null
  started_at: string | null
  finished_at: string | null
  cleaned_up_at: string | null
  steps_count: number
  job: {
    id: number
    title: string
    title_pending?: boolean
    state: string
    repository: DashboardRepository
    owner_user: DashboardOwnerUser | null
    owner_badge: DashboardOwnerBadge | null
    path: string
  }
}

export type DashboardItem = DashboardJobItem | DashboardEpicItem | DashboardWorkflowItem

export type DashboardLane = {
  key: string
  title: string
  count: number
  total_count?: number
  loaded_count?: number
  has_more?: boolean
  next_offset?: number
  items: DashboardItem[]
}

export type DashboardKanbanLaneOption = {
  key: string
  title: string
}

export type DashboardColumnOption = {
  key: string
  title: string
}

export type DashboardSmartFolder = {
  id: number
  name: string
  key?: string | null
  kind: string
  position: number
  subject_type: string
  visibility: string
  count: number | null
  blocked_count?: number | null
  active: boolean
  filter?: Record<string, unknown>
  attention_preset: string | null
  path: string
}

export type DashboardFilterOption = {
  value: string | number
  label: string
}

export type DashboardFilterSchemaField = {
  field: string
  label: string
  bucket: string
  operators: string[]
  values?: Array<DashboardFilterOption | string>
  typeahead?: boolean
  expansions?: Record<string, unknown>
}

export type DashboardFilterSuggestion = {
  id: number | string
  label: string
  filter: Record<string, unknown>
  source?: string
  use_count?: number
  last_used_at?: string | null
}

export type DashboardPayload = {
  simple_mode?: boolean
  subject: DashboardSubject
  view: string
  page: number
  per_page: number
  total: number
  total_pages: number
  total_estimated?: boolean
  counts: {
    jobs: number
    epics: number
    workflows: number
  }
  ownership_scope: {
    scope: string
    owner_user_id: number | null
    owner_user: DashboardOwnerUser | null
  }
  preferences: {
    sort: Record<string, string>
    visible_columns: string[]
    kanban_lanes: string[]
    ownership_scope: string
    owner_user_id: number | null
    owner_id: number | null
    raw: Record<string, unknown>
  }
  filter?: Record<string, unknown> | null
  controls: {
    views: string[]
    ownership_scopes: Array<{ value: string; label: string }>
    owners: Array<{ id: number; label: string; current: boolean }>
    sort_columns: string[]
    sort_directions: string[]
    columns: {
      required: DashboardColumnOption[]
      optional: DashboardColumnOption[]
    }
    kanban_lanes: DashboardKanbanLaneOption[]
    filter_schema: DashboardFilterSchemaField[]
    filter_suggestions: DashboardFilterSuggestion[]
  }
  landing_queue: {
    visible: boolean
    paused: boolean
    toggle_path: string
    entries?: DashboardLandingQueueEntry[]
  }
  provider_availability?: Record<string, ProviderAvailability>
  broken_repositories?: DashboardHealthBlockedRepository[]
  health_blocked_repositories?: DashboardHealthBlockedRepository[]
  ownership: {
    scope: string
    owner_id: number | null
    team_user_count: number
    badges_visible: boolean
  }
  smart_folders: DashboardSmartFolder[]
  active_smart_folder_id: number | null
  items: DashboardItem[]
  lanes: DashboardLane[]
  kanban_limit: number | null
  setup?: SetupStatusPayload
  rows_current_for_search?: boolean
  paths: {
    dashboard_path: string
    dashboard_jobs_path: string
    dashboard_epics_path: string
    dashboard_workflows_path: string
    new_epic_path: string
    new_job_path: string
    app_dashboard_path: string
  }
}

export type DashboardChromePayload = Omit<DashboardPayload, "total" | "total_pages" | "total_estimated" | "items" | "lanes" | "kanban_limit"> & {
  total?: number
  total_pages?: number
  total_estimated?: boolean
  items?: DashboardItem[]
  lanes?: DashboardLane[]
  kanban_limit?: number | null
}

export type DashboardRowsPayload = Pick<DashboardPayload, "subject" | "view" | "page" | "per_page" | "total" | "total_pages" | "total_estimated" | "landing_queue" | "items" | "lanes" | "kanban_limit"> & Partial<Pick<DashboardPayload, "active_smart_folder_id" | "filter" | "preferences">> & {
  controls?: Partial<DashboardPayload["controls"]>
}

export type DashboardPreferencesInput = {
  subject: DashboardSubject
  active_smart_folder_id?: number | null
  view?: string
  smart_folder_id?: number | null
  sort_column?: string
  sort_direction?: string
  visible_columns?: string[]
  kanban_lanes?: string[]
}

export type DashboardPreferencesPayload = {
  message: string
  dashboard_preferences: Record<string, unknown>
}

export type DashboardBulkJobAction = "retry" | "close" | "approve" | "claim" | "release_claim" | "pause" | "unpause"
export type DashboardBulkEpicAction = "start"

export type DashboardBulkJobsInput = {
  job_ids: number[]
  bulk_action: DashboardBulkJobAction | string
  tag_id?: number
  tag_name?: string
}

export type DashboardBulkJobsPayload = {
  message: string
  action: string
  affected_job_ids: number[]
  skipped_job_ids: number[]
}

export type DashboardBulkEpicsInput = {
  epic_ids: number[]
  bulk_action: DashboardBulkEpicAction | string
}

export type DashboardBulkEpicsPayload = {
  message: string
  action: string
  affected_epic_ids: number[]
  skipped_epic_ids: number[]
}

export type DashboardLandingPausePayload = {
  message: string
  landing_paused: boolean
}

export type DashboardSmartFolderCreateInput = {
  subject: DashboardSubject
  name: string
  filters: Record<string, string>
}

export type DashboardFilterUsageInput = {
  subject: DashboardSubject
  filter: Record<string, unknown>
}

export type DashboardFilterUsagePayload = {
  recorded: boolean
}

export type DashboardSmartFolderCreatePayload = {
  message: string
  redirect_to: string
  smart_folder: {
    id: number
    name: string
    position: number
    filter: unknown
  }
}

export type DashboardEpicStatePayload = {
  message?: string | null
}

export type DashboardGraphNode = {
  id: string
  kind: "epic" | "job"
  label: string
  state: string
  epic_id: number | null
  url: string
  is_focal: boolean
}

export type DashboardGraphEdge = {
  from_id: string
  to_id: string
}

export type DashboardGraphPayload = {
  nodes: DashboardGraphNode[]
  edges: DashboardGraphEdge[]
}

export function fetchJobsGraph(search = "", options: { signal?: AbortSignal } = {}) {
  return getJson<DashboardGraphPayload>(`/api/v1/app/jobs/graph${search}`, options)
}

export function fetchEpicsGraph(search = "", options: { signal?: AbortSignal } = {}) {
  return getJson<DashboardGraphPayload>(`/api/v1/app/epics/graph${search}`, options)
}

export function fetchDashboard(search = "", options: { signal?: AbortSignal } = {}) {
  return getJson<DashboardPayload>(`/api/v1/app/dashboard${search}`, options)
}

export function fetchDashboardChrome(search = "", options: { signal?: AbortSignal } = {}) {
  return getJson<DashboardChromePayload>(`/api/v1/app/dashboard${dashboardSectionSearch(search, "chrome")}`, options)
}

export function fetchDashboardChromeWithMeta(search = "", options: { signal?: AbortSignal } = {}) {
  return getJsonWithMeta<DashboardChromePayload>(`/api/v1/app/dashboard${dashboardSectionSearch(search, "chrome")}`, options)
}

export function fetchDashboardRows(search = "", options: { signal?: AbortSignal } = {}) {
  return getJson<DashboardRowsPayload>(`/api/v1/app/dashboard${dashboardSectionSearch(search, "rows")}`, options)
}

export function fetchDashboardRowsWithMeta(search = "", options: { signal?: AbortSignal } = {}) {
  return getJsonWithMeta<DashboardRowsPayload>(`/api/v1/app/dashboard${dashboardSectionSearch(search, "rows")}`, options)
}

export type DashboardTimedPayload<T> = {
  data: T
  meta: JsonResponseMeta
}

export function mergeDashboardPayload(chrome: DashboardChromePayload, rows: DashboardRowsPayload, options: { rowsCurrentForSearch?: boolean } = {}): DashboardPayload {
  const activeSmartFolderId = rows.active_smart_folder_id ?? chrome.active_smart_folder_id
  const rowControls = rows.controls ?? {}

  return {
    ...chrome,
    ...rows,
    counts: chrome.counts,
    controls: {
      ...chrome.controls,
      ...rowControls,
      columns: rowControls.columns ?? chrome.controls.columns
    },
    ownership_scope: chrome.ownership_scope,
    preferences: rows.preferences ?? chrome.preferences,
    ownership: chrome.ownership,
    filter: rows.filter ?? chrome.filter,
    landing_queue: {
      ...chrome.landing_queue,
      ...rows.landing_queue
    },
    provider_availability: chrome.provider_availability,
    broken_repositories: chrome.broken_repositories,
    health_blocked_repositories: chrome.health_blocked_repositories,
    smart_folders: chrome.smart_folders.map((folder) => ({ ...folder, active: folder.id === activeSmartFolderId })),
    active_smart_folder_id: activeSmartFolderId,
    setup: chrome.setup,
    rows_current_for_search: options.rowsCurrentForSearch ?? true,
    paths: chrome.paths
  }
}

export function dashboardApiSearch(pathname: string, search: string) {
  const params = new URLSearchParams(search)
  const subject = dashboardSubjectFromPath(pathname)
  if (subject) params.set("subject", subject)

  const next = params.toString()
  return next ? `?${next}` : ""
}

export function dashboardChromeSearch(pathname: string, search: string) {
  const params = new URLSearchParams(dashboardApiSearch(pathname, search))
  params.delete("smart_folder_id")
  params.delete("page")

  const next = params.toString()
  return next ? `?${next}` : ""
}

function dashboardSectionSearch(search: string, section: "chrome" | "rows") {
  const params = new URLSearchParams(search.startsWith("?") ? search.slice(1) : search)
  params.set("section", section)
  const next = params.toString()
  return next ? `?${next}` : ""
}

function dashboardSubjectFromPath(pathname: string): DashboardSubject | null {
  if (pathname.endsWith("/dashboard/jobs")) return "job"
  if (pathname.endsWith("/dashboard/workflows")) return "workflow"
  if (pathname.endsWith("/dashboard/epics")) return "epic"

  return null
}

export function updateDashboardPreferences(input: DashboardPreferencesInput) {
  return patchJson<DashboardPreferencesPayload>("/api/v1/app/dashboard/preferences", input)
}

export function bulkDashboardJobs(input: DashboardBulkJobsInput) {
  return postJson<DashboardBulkJobsPayload>("/api/v1/app/dashboard/jobs/bulk", input)
}

export function pauseDashboardJob(path: string) {
  return postJson<{ message?: string }>(path, {})
}

export function unpauseDashboardJob(path: string) {
  return postJson<{ message?: string }>(path, {})
}

export function bulkDashboardEpics(input: DashboardBulkEpicsInput) {
  return postJson<DashboardBulkEpicsPayload>("/api/v1/app/dashboard/epics/bulk", input)
}

export function updateDashboardEpicState(path: string, targetState: string) {
  return patchJson<DashboardEpicStatePayload>(path, { target_state: targetState })
}

export function toggleDashboardLandingPause(path: string) {
  return postJson<DashboardLandingPausePayload>(path, {})
}

export function requestDashboardMainBranchRepair(path: string) {
  return postJson<{ message?: string }>(path, {})
}

export function recordDashboardFilterUsage(input: DashboardFilterUsageInput) {
  return postJson<DashboardFilterUsagePayload>("/api/v1/app/filters/usage", {
    surface: "dashboard",
    subject: input.subject,
    filter: input.filter
  })
}

export function createDashboardSmartFolder(input: DashboardSmartFolderCreateInput) {
  return postJson<DashboardSmartFolderCreatePayload>("/api/v1/app/smart_folders", {
    ...input.filters,
    subject_type: input.subject,
    smart_folder: { name: input.name }
  })
}
