import { getJson, postJson } from "./client"
import { reapStaleRuns } from "./adminQueue"

export type ConsoleSettings = {
  polling_paused: boolean
  runs_paused: boolean
  signups_open: boolean
  max_job_failures: number
  grade_max_iterations: number
  merge_train_enabled: boolean
}

export type ConsoleUser = {
  id: number
  email_address: string
  display_name: string
}

export type ConsoleAction = {
  id: number
  action: string
  performed_at: string
  user_email: string
  params: Record<string, unknown>
}

export type AdminConsolePayload = {
  settings: ConsoleSettings
  users: ConsoleUser[]
  recent_admin_actions: ConsoleAction[]
  active_runs: number
  ok?: boolean
  message?: string
}

export type ConsoleCommand =
  | "pause_polling"
  | "unpause_polling"
  | "pause_runs"
  | "unpause_runs"
  | "enable_merge_train"
  | "disable_merge_train"

export function fetchAdminConsole() {
  return getJson<AdminConsolePayload>("/api/v1/app/admin/console")
}

export function runConsoleCommand(command: ConsoleCommand) {
  return postJson<AdminConsolePayload>(`/api/v1/app/admin/console/${command}`)
}

export function clearGithubCache(userId: string) {
  const body = userId.length > 0 ? { user_id: userId } : undefined
  return postJson<AdminConsolePayload>("/api/v1/app/admin/console/clear_github_cache", body)
}

export { reapStaleRuns }
