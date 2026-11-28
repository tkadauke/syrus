import { deleteJson, getJson, patchJson, postJson } from "./client"

export type BuildNetworkRule = {
  id: number
  source_class: string
  host: string
  port: number | null
  path_prefix: string | null
  ecosystem: string | null
  required: boolean
  enabled: boolean
  note: string | null
}

export type BuildNetworkRuleInput = Omit<BuildNetworkRule, "id">

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
  coworker_environment_recovery: {
    rollback_retention_count: number
    launch_failure_threshold: number
  }
  runtime_environment: {
    policy: {
      builder: Record<string, number>
      supply_chain: { blocked_severities: string[]; prohibited_packages: string[] }
      base_promotion: { minimum_abi: number; maximum_abi: number }
      recovery: { launch_failure_threshold: number; rollback_retention_count: number }
      revocation: { terminate_running_turns_on_severe: boolean }
      worker_cache: Record<string, number>
      scratch: { enabled: boolean; size_bytes: number }
    }
    oci_registry: {
      configured: boolean
      url?: string
      repository_prefix?: string
      secure?: boolean
      error?: string
      credentials: Record<string, boolean>
    }
    build_network_rules: BuildNetworkRule[]
    build_network_source_classes: Array<{
      key: string
      ecosystem_required: boolean
      ecosystem_input_mode: "none" | "select" | "freeform"
      ecosystem_options: string[]
      path_scoped: boolean
      requirable: boolean
    }>
  }
  message?: string
}

export type RetentionSettingsUpdate = Record<string, number | boolean | Record<string, unknown>>

export function fetchRetentionSettings() {
  return getJson<RetentionSettingsPayload>("/api/v1/app/admin/retention_settings")
}

export function updateRetentionSettings(values: RetentionSettingsUpdate) {
  return patchJson<RetentionSettingsPayload>("/api/v1/app/admin/retention_settings", {
    retention_settings: values
  })
}

const networkRulesPath = "/api/v1/app/admin/retention_settings/network_rules"

export function createBuildNetworkRule(rule: BuildNetworkRuleInput) {
  return postJson<RetentionSettingsPayload>(networkRulesPath, { rule })
}

export function updateBuildNetworkRule(id: number, rule: BuildNetworkRuleInput) {
  return patchJson<RetentionSettingsPayload>(`${networkRulesPath}/${id}`, { rule })
}

export function deleteBuildNetworkRule(id: number) {
  return deleteJson<RetentionSettingsPayload>(`${networkRulesPath}/${id}`)
}
