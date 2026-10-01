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
    grade_max_iterations: number
    adversarial_review_rounds: number
    max_job_failures: number
    merge_train_max_size: number
    main_concern_report_threshold: number
    main_branch_breakage_policy: "strict" | "isolate_unrelated_failures"
    report_issue_repo_slug: string
    video_retention_days: number
    video_storage_budget_mb: number
    telegram_bot_handle: string | null
    max_concurrent_agent_runs: number
    proactive_rebase_commit_threshold: number
    show_work_unit_debug: boolean
    rebase_failure_cooldown_minutes: number
    workflow_admission_control_enabled: boolean
    workflow_admission_policy: "whole_workflow" | "phase_aware"
    chat_coding_workspace_budget_mb: number
    workflow_admission_control_changed_at: string | null
    workflow_admission_control_changed_by: {
      id: number
      email_address: string
      display_name?: string | null
    } | null
    metadata?: AdminSettingMetadata[]
    clearable_secrets: ClearableSecret[]
  }
  message?: string
}

export type AdminSettingsUpdate = {
  signups_open?: boolean
  grade_max_iterations?: number
  adversarial_review_rounds?: number
  max_job_failures?: number
  merge_train_max_size?: number
  main_concern_report_threshold?: number
  main_branch_breakage_policy?: "strict" | "isolate_unrelated_failures"
  report_issue_repo_slug?: string
  video_retention_days?: number
  video_storage_budget_mb?: number
  telegram_bot_handle?: string
  max_concurrent_agent_runs?: number
  proactive_rebase_commit_threshold?: number
  show_work_unit_debug?: boolean
  rebase_failure_cooldown_minutes?: number
  workflow_admission_control_enabled?: boolean
  workflow_admission_policy?: "whole_workflow" | "phase_aware"
  chat_coding_workspace_budget_mb?: number
  telegram_bot_token?: string
  discord_bot_token?: string
}

export type PlatformPollingConnectorStatus = "started" | "already_running" | "not_configured" | "error"

export type PlatformPollingConnector = {
  name: string
  status: PlatformPollingConnectorStatus
  platform?: string
}

export type PlatformPollingStartResult = {
  started: string[]
  connectors: PlatformPollingConnector[]
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
