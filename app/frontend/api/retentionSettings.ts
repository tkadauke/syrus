import { getJson, patchJson } from "./client"

export type RetentionTableRow = {
  key: string
  table_name: string
  description: string
  category: string
  setting_key: string
  unit: "days" | "hours"
  default_value: number
  retention_value: number
  row_count_estimate?: number | null
  byte_size_estimate?: number | null
  estimated_max_byte_size?: number | null
  computed_at?: string | null
  archivable: boolean
  archive_setting_key: string | null
  archive_before_delete: boolean
}

export type RetentionAvailableSpace = {
  available_bytes: number | null
  source: "measured" | "manual" | "unknown"
  computed_at: string
}

export type RetentionSettingsPayload = {
  tables: RetentionTableRow[]
  available_space: RetentionAvailableSpace | null
  retention_available_space_override_gb: number
  storage_limits: {
    prepared_layer_cache_default_bytes: number
    coding_workspace_bytes: number
    prepared_layer_cache_workers: Array<{
      hostname: string
      worker_storage_key: string | null
      budget_bytes: number
      source: "app_setting" | "worker_environment"
      observed_at: string
    }>
  }
  message?: string
}

export type RetentionSettingsUpdate = Record<string, number | boolean>

export function fetchRetentionSettings() {
  return getJson<RetentionSettingsPayload>("/api/v1/app/admin/retention_settings")
}

export function updateRetentionSettings(values: RetentionSettingsUpdate) {
  return patchJson<RetentionSettingsPayload>("/api/v1/app/admin/retention_settings", {
    retention_settings: values
  })
}
