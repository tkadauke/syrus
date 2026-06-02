import { getJson, patchJson, postJson } from "./client"

import type { SetupStatusPayload } from "./setup"

export type DashboardSubject = "job" | "epic" | "workflow"

export type DashboardRepository = {
  id: number
  slug: string
}

export type DashboardOwner = {
  id: number
  email_address: string
  display_name: string
}

export type DashboardOwnerUser = {
  id: number
  name: string
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

export type DashboardOwnerUser = {
  id: number
  email_address: string
}

export type DashboardJobItem = {
  type: "job"
  id: number
  kind: string
  title: string
  state: string
  summary_state: string
  validity: string
  priority: string
  total_cost_usd: number | null
  issue_number: number | null
  issue_url: string | null
  branch_name: string | null
  pr_number: number | null
  latest_workflow_trigger_kind: string | null
  pr_url: string | null
  latest_workflow_state: string
  created_at: string | null
  updated_at: string | null
  started_at: string | null
  finished_at: string | null
  approved_at: string | null
  dependencies_overridden_at: string | null
  last_feedback_addressed_at: string | null
  last_seen_comment_at: string | null
  pr_mergeable_checked_at: string | null
  workflows_count: number
  repository: DashboardRepository
  owner_user: DashboardOwnerUser | null
  owner_badge: DashboardOwnerBadge | null
  tags: DashboardTag[]
  paths: {
    job_path: string
    source_path: string
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
  owner: DashboardOwner | null
  owned_by_current_user: boolean
  claimable: boolean
  owner_badge: DashboardOwnerBadge | null
  claimed_at: string | null
  auto_approve_mode: string
  owner_user_id: number | null
  owner_status: "mine" | "other_owned" | "unclaimed"
  owner_user: DashboardOwnerUser | null
  jobs_count: number
  created_at: string | null
  updated_at: string | null
  done_at: string | null
  archived_at: string | null
  repository: DashboardRepository
  owner_user: DashboardOwnerUser | null
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
  kind: string
  subject_type: string
  visibility: string
  count: number
  active: boolean
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

export type DashboardPayload = {
  subject: DashboardSubject
  view: string
  page: number
  per_page: number
  total: number
  total_pages: number
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
  }
  landing_queue: {
    visible: boolean
    paused: boolean
    toggle_path: string
  }
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

export type DashboardPreferencesInput = {
  subject: DashboardSubject
  sort_column?: string
  sort_direction?: string
  visible_columns?: string[]
  kanban_lanes?: string[]
}

export type DashboardPreferencesPayload = {
  message: string
  dashboard_preferences: Record<string, unknown>
}

export type DashboardBulkJobAction = "retry" | "close" | "approve"
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

export function fetchDashboard(search = "") {
  return getJson<DashboardPayload>(`/api/v1/app/dashboard${search}`)
}

export function updateDashboardPreferences(input: DashboardPreferencesInput) {
  return patchJson<DashboardPreferencesPayload>("/api/v1/app/dashboard/preferences", input)
}

export function bulkDashboardJobs(input: DashboardBulkJobsInput) {
  return postJson<DashboardBulkJobsPayload>("/api/v1/app/dashboard/jobs/bulk", input)
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

export function createDashboardSmartFolder(input: DashboardSmartFolderCreateInput) {
  return postJson<DashboardSmartFolderCreatePayload>("/api/v1/app/smart_folders", {
    ...input.filters,
    subject_type: input.subject,
    smart_folder: { name: input.name }
  })
}
