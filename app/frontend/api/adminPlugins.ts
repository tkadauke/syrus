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
  name: string
  display_name: string
  version: string
  enabled: boolean
  default_enabled: boolean
  disableable: boolean
  category: string | null
  category_label: string | null
  description: string | null
  homepage: string | null
  icon_url: string | null
  author: string | null
  source: string | null
  extension_points: AdminPluginExtensionPoint[]
  depends_on?: string[]
  dependents?: string[]
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

export function enableAdminPlugin(name: string) {
  return postJson<AdminPluginsPayload>(`/api/v1/app/admin/plugins/${encodeURIComponent(name)}/enable`)
}

export function disableAdminPlugin(name: string, confirmCascade = false) {
  return postJson<AdminPluginsPayload | AdminPluginDisableConfirmation>(
    `/api/v1/app/admin/plugins/${encodeURIComponent(name)}/disable`,
    confirmCascade ? { confirm_cascade: true } : undefined
  )
}
