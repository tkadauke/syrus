import { getJson, patchJson, postJson } from "./client"

export type ClearableSecret = {
  key: string
  label: string
  set: boolean
}

export type AdminSettingMetadata = {
  key: string
  type: string
  default?: boolean | number | string | null
  category: string
  operational_meaning: string
  min?: number
  max?: number
  zero_means?: string
  admin_editable: boolean
  secret: boolean
}

export type AdminSettingsPayload = {
  settings: {
    signups_open: boolean
    video_retention_days: number
    video_storage_budget_mb: number
    max_concurrent_agent_runs: number
    proactive_rebase_commit_threshold: number
    rebase_failure_cooldown_minutes: number
    workflow_admission_control_enabled: boolean
    workflow_admission_policy: "whole_workflow" | "phase_aware"
    workflow_admission_control_changed_at: string | null
    workflow_admission_control_changed_by: {
      id: number
      email_address: string
      display_name?: string | null
    } | null
    mode: "advanced" | "simple"
    metadata?: AdminSettingMetadata[]
    clearable_secrets: ClearableSecret[]
  }
  message?: string
}

export type AdminSettingsUpdate = {
  signups_open?: boolean
  video_retention_days?: number
  video_storage_budget_mb?: number
  max_concurrent_agent_runs?: number
  proactive_rebase_commit_threshold?: number
  rebase_failure_cooldown_minutes?: number
  workflow_admission_control_enabled?: boolean
  workflow_admission_policy?: "whole_workflow" | "phase_aware"
  mode?: "advanced" | "simple"
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
