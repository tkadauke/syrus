import { deleteJson, getJson, patchJson, postForm, postJson } from "@app/api/client"

export type CoworkerSummary = {
  id: number | "syrus"
  name: string
  handle: string
  role_summary: string | null
  state: string
  accent_hex: string
  avatar_key: string | null
  avatar_url: string | null
  path: string
  built_in?: boolean
  chat_model?: string | null
  weekly_spend_usd?: number
}
export type CoworkerDetail = CoworkerSummary & {
  chat_provider: string | null
  chat_model: string | null
  effective_model: string | null
  workspace_repo: string
  about: string | null
  soul: string | null
  chats: { id: number; link_id: number; role: "main" | "side"; title: string; path: string; unsaved_workspace: UnsavedWorkspace | null }[]
  grants: {
    capability: string
    approval_policy: string
    constraints: { confirm_paths?: string[]; max_spawns_per_run?: number; max_spawns_per_day?: number }
    scope?: unknown
  }[]
  grant_catalog: {
    name: string
    label: string
    description: string
    default_policy: "queue" | "confirm" | "auto"
    maximum_policy: "off" | "queue" | "confirm" | "auto"
    tools: string[]
    scopeable: boolean
    scope_options?: { value: unknown; label: string }[]
    default_enabled: boolean
    privileged?: boolean
    available?: boolean
    unavailable_reason?:
      | "confinement_unavailable"
      | "confinement_worker_unavailable"
      | "confinement_configuration_missing"
      | "confinement_probe_missing"
      | "confinement_probe_failed"
      | "broker_authorization_unavailable"
      | null
  }[]
  schedules: CoworkerSchedule[]
  available_chats: { id: number; title: string; rostered: boolean; implicit: boolean }[]
  message_traffic: {
    sent: number
    received: number
    window_days: number
    delivery_events: { status: "refused" | "rate_limited"; receiver_handle: string; reason: string; occurred_at: string }[]
  }
}
export type CoworkerConversation = {
  id: number
  title: string
  path: string
  main: boolean
  preview: string | null
  last_activity_at: string
  created_at: string
  archived: boolean
  unread: boolean
  active_work: boolean
  title_match: boolean
  match_count: number
  match: { message_id: number; snippet: string } | null
}
export type CoworkerConversationIndex = {
  main_chat: CoworkerConversation | null
  side_chats: CoworkerConversation[]
  result_count: number
  result_count_exact: boolean
  next_cursor: string | null
  filter: Record<string, unknown>
  filter_schema: import("@app/components/FilterBar").FilterSchemaField[]
  sort: "last_activity" | "title" | "created_at"
}
export type UnsavedWorkspace = {
  branch: string
  path: string
  last_error: string
  failure_kind: "transient" | "permanent"
  operation: "chat_branch" | "home_branch"
  first_failed_at: string
  last_failed_at: string
  attempt_count: number
  retry_exhausted: boolean
}
export type CoworkerSchedule = {
  id: number
  name: string
  prompt: string
  kind: "cron" | "one_shot"
  state: string
  schedule_input: string | null
  schedule_explanation: string | null
  fire_at: string | null
  next_fire_at: string | null
  last_fired_at: string | null
  after_run: "wake" | "quiet"
  system_key: string | null
  last_journaled_on: string | null
  last_system_result: string | null
  last_system_result_reason: string | null
  journaling_overdue: boolean
  latest_result: {
    occurred_at: string | null
    target_date: string | null
    outcome: string
    reason: string | null
    job: { id: number; slug: string; path: string } | null
    job_needed: boolean | null
  }
}
export type CoworkerActivityPayload = {
  spend: { week_usd: number; total_usd: number }
  runs: {
    id: number
    job_id: number
    state: string
    started_at: string | null
    finished_at: string | null
    tool_calls_count: number
    cost_usd: number
  }[]
  side_chats: { id: number; title: string | null; path: string; cost_usd: number }[]
  next_cursors: { runs: string | null; side_chats: string | null }
  message_traffic: CoworkerDetail["message_traffic"]
}
export type CoworkerApproval = {
  id: number
  tool_name: string
  tool_input: Record<string, unknown>
  run_id: number | null
  chat_id: number
  created_at: string
  state: string
  actor: {
    name: string
    handle: string
    avatar_key: string | null
    avatar_url: string | null
    accent_hex: string | null
  }
}
export type CoworkerModelOptions = {
  provider: string
  provider_label: string
  models: { id: string; label: string }[]
}
export type ProvisioningAttempt = {
  id: number
  handle: string
  branch: string
  state: string
  retry_count: number
  last_error: string | null
  acknowledged_at: string | null
}
export type CoworkerWorkspacePayload = {
  remote: string
  branch: string
  files: { path: string; type: string; size: number | null; extension: string; area: string }[]
  results: { path: string; type: string; size: number | null; extension: string; area: string; binary?: boolean; truncated?: boolean; snippet: string | null; highlights: { start: number; length: number }[]; last_modified_at: string | null }[]
  total: number
  next_cursor: string | null
  incomplete_reasons: string[]
  partial: boolean
  selected_file: { path: string; content: string; truncated: boolean; binary: boolean } | null
  commits: { sha: string; message: string; authored_at: string | null; source: "chat" | "run" | "unattributed"; source_id: number | null }[]
  conflicts: { branch: string; files: string[]; detail: string | null }[]
  branch_counts: { home: number | null; chat: number | null; run: number | null }
}

export const fetchCoworkers = () =>
  getJson<{
    coworkers: CoworkerSummary[]
    syrus: CoworkerSummary
    provisioning_attempts: ProvisioningAttempt[]
  }>("/api/v1/app/coworkers")
export const fetchCoworkerOptions = () =>
  getJson<{
    accent_hexes: string[]
    model_options: CoworkerModelOptions[]
    grant_catalog: CoworkerDetail["grant_catalog"]
  }>("/api/v1/app/coworkers/options")
export const retryProvisioningCleanup = (id: number) => postJson(`/api/v1/app/coworkers/provisioning_attempts/${id}/retry`)
export const acknowledgeProvisioningCleanup = (id: number) => postJson(`/api/v1/app/coworkers/provisioning_attempts/${id}/acknowledge`)
export function fetchCoworker(id: string) {
  return getJson<{ coworker: CoworkerSummary & Pick<CoworkerDetail, "chat_provider" | "chat_model" | "effective_model" | "workspace_repo" | "about"> }>(
    `/api/v1/app/coworkers/${id}`
  )
}
export function fetchCoworkerTab(id: string, tab: "profile" | "chats" | "capabilities" | "schedules") {
  return getJson<Partial<CoworkerDetail>>(`/api/v1/app/coworkers/${id}/${tab}`)
}
export function fetchCoworkerConversationIndex(id: string, search = "") {
  return getJson<CoworkerConversationIndex>(`/api/v1/app/coworkers/${id}/conversation_index${search}`)
}
export const renameCoworkerConversation = (chatId: number, title: string) => patchJson(`/api/v1/app/chats/${chatId}/rename`, { name: title })
export const archiveCoworkerConversation = (chatId: number, archived: boolean) => patchJson(`/api/v1/app/chats/${chatId}/${archived ? "unhide" : "hide"}`)
export const deleteCoworkerConversation = (chatId: number) => deleteJson(`/api/v1/app/chats/${chatId}`)
export function fetchCoworkerWorkspace(id: string, search: string) {
  return getJson<CoworkerWorkspacePayload>(`/api/v1/app/coworkers/${id}/workspace${search}`)
}
export const retryCoworkerWorkspaceSave = (id: string, chatLinkId: number) => postJson(`/api/v1/app/coworkers/${id}/workspace/retry`, { chat_id: chatLinkId })
export function fetchCoworkerActivity(id: string, cursors?: { runs?: string | null; sideChats?: string | null }) {
  const query = new URLSearchParams()
  if (cursors) {
    query.set("runs_cursor", cursors.runs || "")
    query.set("side_chats_cursor", cursors.sideChats || "")
  }
  return getJson<CoworkerActivityPayload>(`/api/v1/app/coworkers/${id}/activity${query.size ? `?${query}` : ""}`)
}
export function fetchCoworkerApprovals(id: string) {
  return getJson<{ approvals: CoworkerApproval[] }>(`/api/v1/app/coworkers/${id}/approvals`)
}
export const decideCoworkerApproval = (coworkerId: string, approvalId: number, decision: "approve" | "reject") =>
  postJson<{ approval: CoworkerApproval }>(`/api/v1/app/coworkers/${coworkerId}/approvals/${approvalId}/${decision}`)
export function createCoworkerSchedule(
  id: string,
  schedule: { name: string; prompt: string; kind: string; schedule_input?: string; fire_at?: string; after_run: "wake" | "quiet" }
) {
  return postJson<{ schedule: CoworkerSchedule }>(`/api/v1/app/coworkers/${id}/schedules`, { schedule })
}
export const updateCoworkerSchedule = (coworkerId: string, scheduleId: number, schedule: { schedule_input: string }) =>
  patchJson<{ schedule: CoworkerSchedule }>(`/api/v1/app/coworkers/${coworkerId}/schedules/${scheduleId}`, { schedule })
export const commandCoworkerSchedule = (coworkerId: string, scheduleId: number, command: "pause" | "resume" | "fire_now") =>
  postJson<{ schedule: CoworkerSchedule; fired?: boolean; reason?: string | null; job_id?: number | null }>(
    `/api/v1/app/coworkers/${coworkerId}/schedules/${scheduleId}/${command}`
  )
export function createCoworker(form: FormData) {
  return postForm<{ coworker: CoworkerDetail; redirect_to: string }>("/api/v1/app/coworkers", form)
}
export function updateCoworker(id: string, attributes: Record<string, string | null>) {
  return patchJson<{ coworker: CoworkerDetail }>(`/api/v1/app/coworkers/${id}`, attributes)
}
export function createSideChat(id: number) {
  return postJson<{ chat_path: string }>(`/api/v1/app/coworkers/${id}/chats`)
}
export const testCoworkerRemote = (workspaceRepo: string) =>
  postJson<{ message: string }>("/api/v1/app/coworkers/test_remote", { workspace_repo: workspaceRepo })
export const addCoworkerToChat = (coworkerId: number, chatId: number) => postJson(`/api/v1/app/chats/${chatId}/agents/${coworkerId}`)
export const removeCoworkerFromChat = (coworkerId: number, chatId: number) => deleteJson(`/api/v1/app/chats/${chatId}/agents/${coworkerId}`)
export const updateCoworkerGrant = (
  id: string,
  capability: string,
  approvalPolicy: string,
  constraints: Record<string, unknown>,
  confirmed = false,
  scope?: unknown
) =>
  patchJson<void>(`/api/v1/app/coworkers/${id}/grants`, {
    capability,
    approval_policy: approvalPolicy,
    constraints,
    confirmed,
    ...(scope === undefined ? {} : { scope })
  })
