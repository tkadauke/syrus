import { getJson, patchJson, postJson } from "./client"

export type ClearableSecret = {
  key: string
  label: string
  set: boolean
}

export type AdminSettingsPayload = {
  settings: {
    signups_open: boolean
    video_retention_days: number
    video_storage_budget_mb: number
    max_concurrent_agent_runs: number
    proactive_rebase_commit_threshold: number
    mode: "advanced" | "simple"
    telegram_bot_handle: string
    clearable_secrets: ClearableSecret[]
  }
  message?: string
}

export type AdminSettingsUpdate = Partial<{
  signups_open: boolean
  video_retention_days: number
  video_storage_budget_mb: number
  max_concurrent_agent_runs: number
  proactive_rebase_commit_threshold: number
  mode: "advanced" | "simple"
  telegram_bot_handle: string
  telegram_bot_token: string
}>

export type PlatformPollingStartResult = {
  started: string[]
}

export function fetchAdminSettings() {
  return getJson<AdminSettingsPayload>("/api/v1/app/admin/settings")
}

export function updateAdminSettings(values: AdminSettingsUpdate) {
  return patchJson<AdminSettingsPayload>("/api/v1/app/admin/settings", {
    app_setting: values
  })
}

export function clearAdminSettingSecret(secret: string) {
  return postJson<AdminSettingsPayload>("/api/v1/app/admin/settings/clear_secret", { secret })
}

export function startPlatformPolling() {
  return postJson<PlatformPollingStartResult>("/api/v1/app/admin/platform_polling/start")
}
