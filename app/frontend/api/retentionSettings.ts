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
  message?: string
}

export type RetentionSettingsUpdate = Record<string, number>

export function fetchRetentionSettings() {
  return getJson<RetentionSettingsPayload>("/api/v1/app/admin/retention_settings")
}

export function updateRetentionSettings(values: RetentionSettingsUpdate) {
  return patchJson<RetentionSettingsPayload>("/api/v1/app/admin/retention_settings", {
    retention_settings: values
  })
}
