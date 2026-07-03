import { getJson, patchJson, postJson } from "./client"

export type ClearableSecret = {
  key: string
  label: string
  set: boolean
}

export type AdminSettingsPayload = {
  settings: {
    signups_open: boolean
    clearable_secrets: ClearableSecret[]
  }
  message?: string
}

export type AdminSettingsUpdate = {
  signups_open: boolean
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
