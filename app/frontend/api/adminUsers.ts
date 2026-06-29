import { getJson, patchJson, postJson } from "./client"
import type { AdminFilteredPayload } from "./adminSmartFolders"

export type GithubRateLimit = {
  remaining: number
  limit: number
  resource: string | null
  reset_at: string | null
  observed_at: string | null
  percent: number | null
}

export type AdminUserRow = {
  id: number
  email_address: string
  name: string | null
  first_name: string | null
  last_name: string | null
  profile_bio: string | null
  profile_location: string | null
  profile_company: string | null
  profile_website: string | null
  display_name: string
  github_handle: string | null
  admin: boolean
  role: string
  scheduling_paused: boolean
  agent_provider: string
  chat_provider: string | null
  codex_auth_mode: string
  has_github_token: boolean
  has_claude_token: boolean
  has_codex_token: boolean
  has_codex_api_key: boolean
  has_codex_auth_json: boolean
  has_api_token: boolean
  agent_max_turns: number
  github_api_blocked: boolean
  github_api_blocked_at: string | null
  github_api_blocked_reason: string | null
  github_rate_limit: GithubRateLimit | null
  created_at: string
  updated_at: string
}

export type RecentJob = {
  id: number
  state: string
  kind: string
  repository_id: number | null
  created_at: string
}

export type RecentRun = {
  id: number
  state: string
  trigger_kind: string
  started_at: string | null
  finished_at: string | null
}

export type RecentAdminAction = {
  action: string
  performed_at: string
  params: Record<string, unknown>
}

export type AdminUserDetail = AdminUserRow & {
  recent_jobs: RecentJob[]
  recent_runs: RecentRun[]
  recent_admin_actions: RecentAdminAction[]
}

export type AdminUsersPayload = AdminFilteredPayload & {
  filters: Record<string, string>
  count: number
  users: AdminUserRow[]
}

export function fetchAdminUsers(search = "") {
  return getJson<AdminUsersPayload>(`/api/v1/app/admin/users${search}`)
}

export function fetchAdminUser(id: string) {
  return getJson<AdminUserDetail>(`/api/v1/app/admin/users/${id}`)
}

export function updateAdminUserRole(id: number, role: string) {
  return patchJson<AdminUserDetail>(`/api/v1/app/admin/users/${id}`, {
    user: { role }
  })
}

export function pauseUserScheduling(id: number) {
  return postJson<AdminUserDetail>(`/api/v1/app/admin/users/${id}/pause_scheduling`)
}

export function unpauseUserScheduling(id: number) {
  return postJson<AdminUserDetail>(`/api/v1/app/admin/users/${id}/unpause_scheduling`)
}
