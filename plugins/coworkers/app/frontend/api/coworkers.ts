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
  soul: string | null
  spend_usd: number
  chats: { id: number; role: "main" | "side"; title: string; path: string }[]
  grants: { capability: string; approval_policy: string; constraints: { confirm_paths?: string[] }; scope?: unknown }[]
  grant_catalog?: {
    name: string
    label: string
    description: string
    maximum_policy: "off" | "queue" | "confirm" | "auto"
    tools: string[]
    scopeable: boolean
    scope_options?: unknown[]
    default_enabled: boolean
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
}
export type CoworkerApproval = {
  id: number
  tool_name: string
  tool_input: Record<string, unknown>
  run_id: number | null
  chat_id: number
  created_at: string
  state: string
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
export type CoworkerMemoryFile = {
  path: string
  category: "daily" | "people" | "repos" | "banks"
  name: string
  content: string
  truncated: boolean
}
export type CoworkerMemoryPayload = {
  files: CoworkerMemoryFile[]
  search: string
  truncated: boolean
  partial: boolean
  search_incomplete: boolean
}
export type CoworkerWorkspacePayload = {
  remote: string
  branch: string
  files: { path: string; type: string }[]
  partial: boolean
  selected_file: { path: string; content: string; truncated: boolean; binary: boolean } | null
  commits: { sha: string; message: string; authored_at: string | null; source: "chat" | "run" | "unattributed"; source_id: number | null }[]
  conflicts: { branch: string; files: string[]; detail: string | null }[]
}

export const fetchCoworkers = () =>
  getJson<{ coworkers: CoworkerSummary[]; syrus: CoworkerSummary; model_options: CoworkerModelOptions[]; provisioning_attempts: ProvisioningAttempt[]; grant_catalog: CoworkerDetail["grant_catalog"] }>(
    "/api/v1/app/coworkers"
  )
export const retryProvisioningCleanup = (id: number) => postJson(`/api/v1/app/coworkers/provisioning_attempts/${id}/retry`)
export const acknowledgeProvisioningCleanup = (id: number) => postJson(`/api/v1/app/coworkers/provisioning_attempts/${id}/acknowledge`)
export function fetchCoworker(id: string) {
  return getJson<{ coworker: CoworkerDetail }>(`/api/v1/app/coworkers/${id}`)
}
export function fetchCoworkerMemory(id: string, search: string) {
  return getJson<CoworkerMemoryPayload>(`/api/v1/app/coworkers/${id}/memory${search}`)
}
export function fetchCoworkerWorkspace(id: string, path?: string) {
  return getJson<CoworkerWorkspacePayload>(`/api/v1/app/coworkers/${id}/workspace${path ? `?path=${encodeURIComponent(path)}` : ""}`)
}
export function fetchCoworkerActivity(id: string) {
  return getJson<CoworkerActivityPayload>(`/api/v1/app/coworkers/${id}/activity`)
}
export function fetchCoworkerApprovals(id: string) {
  return getJson<{ approvals: CoworkerApproval[] }>(`/api/v1/app/coworkers/${id}/approvals`)
}
export const decideCoworkerApproval = (coworkerId: string, approvalId: number, decision: "approve" | "reject") =>
  postJson<{ approval: CoworkerApproval }>(`/api/v1/app/coworkers/${coworkerId}/approvals/${approvalId}/${decision}`)
export const createCoworkerSchedule = (id: string, schedule: { name: string; prompt: string; kind: string; schedule_input?: string; fire_at?: string }) =>
  postJson<{ schedule: CoworkerSchedule }>(`/api/v1/app/coworkers/${id}/schedules`, { schedule })
export const commandCoworkerSchedule = (coworkerId: string, scheduleId: number, command: "pause" | "resume" | "fire_now") =>
  postJson<{ schedule: CoworkerSchedule; fired?: boolean; reason?: string | null; job_id?: number | null }>(
    `/api/v1/app/coworkers/${coworkerId}/schedules/${scheduleId}/${command}`
  )
export function createCoworker(form: FormData) {
  return postForm<{ coworker: CoworkerDetail; redirect_to: string }>("/api/v1/app/coworkers", form)
}
export function createSideChat(id: number) {
  return postJson<{ chat_path: string }>(`/api/v1/app/coworkers/${id}/chats`)
}
export const testCoworkerRemote = (workspaceRepo: string) =>
  postJson<{ message: string }>("/api/v1/app/coworkers/test_remote", { workspace_repo: workspaceRepo })
export const addCoworkerToChat = (coworkerId: number, chatId: number) => postJson(`/api/v1/app/chats/${chatId}/agents/${coworkerId}`)
export const removeCoworkerFromChat = (coworkerId: number, chatId: number) => deleteJson(`/api/v1/app/chats/${chatId}/agents/${coworkerId}`)
export const updateCoworkerGrant = (id: string, capability: string, approvalPolicy: string, constraints: Record<string, unknown>, confirmed = false) =>
  patchJson<{ coworker: CoworkerDetail }>(`/api/v1/app/coworkers/${id}/grants`, {
    capability,
    approval_policy: approvalPolicy,
    constraints,
    confirmed
  })
