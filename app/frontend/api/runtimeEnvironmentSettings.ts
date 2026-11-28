import { deleteJson, getJson, patchJson, postJson } from "./client"

export type NetworkRule = { id: number; source_class: string; host: string | null; port: number | null; path_prefix: string | null; ecosystem: string | null; required: boolean; enabled: boolean; note: string | null }
export type RuntimeEnvironmentPolicy = {
  builder: { max_concurrent_builds: number; max_concurrent_per_namespace: number; cpus: number; memory_bytes: number; storage_bytes: number; timeout_seconds: number; log_bytes: number }
  verification: { blocked_severities: string[]; prohibited_packages: string[] }
  base: { promotion_requires_compatible_abi: boolean; rollback_retention_days: number }
  revocation: { terminate_running_on_severe: boolean }
  cache: { max_concurrent_pulls: number; pull_timeout_seconds: number; high_pressure_percent: number; critical_pressure_percent: number; prefetch_active: boolean }
  runtime: { mount_profile: "standard" | "executable_scratch"; scratch_size: string }
}
export type RuntimeEnvironmentSettingsPayload = {
  registry: { url: string; repository_prefix: string; credentials: Record<"builder" | "worker" | "admin", { username: string; password_set: boolean }> }
  policy: RuntimeEnvironmentPolicy
  network_rules: NetworkRule[]
  source_classes: string[]
  language_ecosystems: string[]
  message?: string
}

export const fetchRuntimeEnvironmentSettings = () => getJson<RuntimeEnvironmentSettingsPayload>("/api/v1/app/admin/runtime_environment_settings")
export const updateRuntimeEnvironmentSettings = (body: object) => patchJson<RuntimeEnvironmentSettingsPayload>("/api/v1/app/admin/runtime_environment_settings", { runtime_environment_settings: body })
export const createNetworkRule = (body: object) => postJson<NetworkRule>("/api/v1/admin/runtime_image_build_network_rules", body)
export const deleteNetworkRule = (id: number) => deleteJson<void>(`/api/v1/admin/runtime_image_build_network_rules/${id}`)
