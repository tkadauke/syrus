import { getJson, postJson } from "./client"
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

export type AdminPlugin = {
  disable_blockers: Array<{ kind: string; label: string; count: number }>
  recommendation?: { reason: string; evidence: string } | null
  health?: { state: string; reasons: string[] }
  name: string
  display_name: string
  version: string
  enabled: boolean
  default_enabled: boolean
  disableable: boolean
  category: string | null
  category_label: string | null
  description: string | null
  long_description?: string | null
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
  depends_on?: string[]
  optionally_depends_on?: string[]
  conflicts_with?: string[]
  dependents?: string[]
  config_schema?: Array<Record<string, unknown>>
  config?: Record<string, unknown>
}

export type AdminPluginsPayload = {
  plugins: AdminPlugin[]
  // Present on the index response (filtered by the FilterBar chip tree);
  // absent from the enable/disable cascade responses, which always return
  // the full unfiltered plugin list.
  filter?: Record<string, unknown>
  controls?: { filter_schema: FilterSchemaField[] }
}

export type AdminPluginDisableConfirmation = {
  requires_confirmation: true
  plugin_name: string
  dependents: string[]
}

export function fetchAdminPlugins(search = "") {
  return getJson<AdminPluginsPayload>(`/api/v1/app/admin/plugins${search}`)
}

export function fetchAdminPlugin(name: string) {
  return getJson<{ plugin: AdminPlugin }>(`/api/v1/app/admin/plugins/${encodeURIComponent(name)}`)
}

export function enableAdminPlugin(name: string) {
  return postJson<AdminPluginsPayload>(`/api/v1/app/admin/plugins/${encodeURIComponent(name)}/enable`)
}

export function disableAdminPlugin(name: string, confirmCascade = false) {
  return postJson<AdminPluginsPayload | AdminPluginDisableConfirmation>(
    `/api/v1/app/admin/plugins/${encodeURIComponent(name)}/disable`,
    confirmCascade ? { confirm_cascade: true } : undefined
  )
}
