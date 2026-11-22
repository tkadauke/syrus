import { getJson, patchJson, postJson } from "./client"
import type { FilterSchemaField } from "../components/FilterBar"

export type AdminPluginExtensionPoint = {
  extension_point: "agent_provider" | "mcp_tool_set" | "input_source" | string
  class_name: string
  availability: {
    status: string
    label: string
    detail?: string | null
    configured_count?: number
  }
}

export type AdminPluginCapability = {
  family: string
  capability: string
  provider: string
  key: string | null
  tier: "stable" | "provisional"
  priority: number
}

export type AdminPlugin = {
  disable_blockers: Array<{ kind: string; label: string; count: number }>
  recommendation?: { reason: string; evidence: string } | null
  health?: {
    state: string
    reasons: string[]
    failures?: Array<{ extension_point: string; operation: string; exception_class: string; message: string; count: number; last_at: string }>
    circuits?: Array<{ extension_point: string; state: string; failure_count: number; opened_at: string; retry_at: string }>
    jobs?: { queue: string; depth: number; failed_count: number; discarded_count: number; last_error?: string | null; last_discarded_at?: string | null }
    host_surface?: {
      public: Array<{ constant: string; tier: string; path: string; line: number }>
      legacy: Array<{ constant: string; tier: string; path: string; line: number }>
      unlisted: Array<{ constant: string; tier: string; path: string; line: number }>
      dynamic: Array<{ constant: string; tier: string; path: string; line: number; method: string }>
      minimum_syrus_version?: string | null
      error?: string | null
    }
  }
  quarantine_clearable?: boolean
  name: string
  display_name: string
  display_name_i18n_key?: string | null
  version: string
  trust_label: "official" | "verified" | "community" | "unsigned_local"
  enabled: boolean
  default_enabled: boolean
  disableable: boolean
  experimental: boolean
  category: string | null
  category_label: string | null
  description: string | null
  description_i18n_key?: string | null
  long_description?: string | null
  long_description_i18n_key?: string | null
  homepage: string | null
  icon_url: string | null
  author: string | null
  source: string | null
  links?: Array<{ label: string; href: string; description?: string | null; kind?: string; enabled_only?: boolean }>
  docs?: Array<{ title: string; path: string; body: string }>
  metrics?: Array<{ name: string; type: string; tags: string[]; comment: string; available: boolean }>
  frontend?: Record<string, unknown>
  routes?: Array<Record<string, unknown>>
  extension_points: AdminPluginExtensionPoint[]
  capabilities?: AdminPluginCapability[]
  depends_on?: string[]
  optionally_depends_on?: string[]
  conflicts_with?: string[]
  dependents?: string[]
  config_schema?: Array<Record<string, unknown>>
  config?: Record<string, unknown>
}

export type AdminPluginsPayload = {
  recovery?: { safe_mode: string | null; quarantines: Record<string, string>; locally_clearable: string[] }
  beta_mode_enabled?: boolean
  convergence?: PluginConvergencePayload
  plugins: AdminPlugin[]
  // Present on the index response (filtered by the FilterBar chip tree);
  // absent from the enable/disable cascade responses, which always return
  // the full unfiltered plugin list.
  filter?: Record<string, unknown>
  controls?: { filter_schema: FilterSchemaField[] }
}

export type PluginConvergencePayload = {
  desired_revision: number
  divergence_threshold_seconds: number
  processes: Array<{
    hostname: string
    role: string
    state: "converged" | "pending_restart" | "behind" | "ahead" | "unreachable"
    running_revision: number | null
    running_digest: string | null
    last_heartbeat_at: string | null
    diverged_since: string | null
    diverged_too_long: boolean
    plugins: Array<{ name: string; desired_version: string; running_version: string | null; state: string; reasons: string[] }>
  }>
}

export type AdminPluginTogglePayload = { ok: true; plugin: { name: string; enabled: boolean } }

export type AdminPluginDisableConfirmation = {
  requires_confirmation: true
  plugin_name: string
  dependents: string[]
}

export type AdminPluginExperimentalBlock = {
  blocked_experimental_plugins: Array<{ name: string; display_name: string }>
  message: string
}

export function fetchAdminPlugins(search = "") {
  return getJson<AdminPluginsPayload>(`/api/v1/app/admin/plugins${search}`)
}

export function fetchAdminPlugin(name: string) {
  return getJson<{ beta_mode_enabled?: boolean; plugin: AdminPlugin }>(`/api/v1/app/admin/plugins/${encodeURIComponent(name)}`)
}

export function enableAdminPlugin(name: string) {
  return postJson<AdminPluginTogglePayload | AdminPluginExperimentalBlock>(`/api/v1/app/admin/plugins/${encodeURIComponent(name)}/enable`)
}

export function disableAdminPlugin(name: string, confirmCascade = false) {
  return postJson<AdminPluginTogglePayload | AdminPluginDisableConfirmation>(
    `/api/v1/app/admin/plugins/${encodeURIComponent(name)}/disable`,
    confirmCascade ? { confirm_cascade: true } : undefined
  )
}

export function clearAdminPluginQuarantine(name: string) {
  return postJson<{ ok: true; plugin: string; restart_required: boolean }>(`/api/v1/app/admin/plugins/${encodeURIComponent(name)}/clear_quarantine`)
}

export function enableBetaModeForInstance() {
  return patchJson<unknown>("/api/v1/app/admin/settings", {
    app_setting: { beta_mode_enabled: true }
  })
}
