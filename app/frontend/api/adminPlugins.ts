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

export type AdminPluginLink = {
  label: string
  path: string
  description?: string | null
  requires_enabled?: boolean
}

export type AdminPluginDoc = {
  title: string
  path: string
  body: string
}

export type AdminPluginMetric = {
  name: string
  type: string
  tags: string[]
  comment?: string | null
  buckets?: number[] | null
  available: boolean
  latest_sample?: {
    value: number
    labels: Record<string, string>
    recorded_at: string | null
  } | null
}

export type AdminPlugin = {
  disable_blockers: Array<{ kind: string; label: string; count: number }>
  recommendation?: { reason: string; evidence: string } | null
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
  frontend?: Record<string, unknown>
  routes?: Array<{ verb?: string; path?: string; controller?: string }>
  extension_points: AdminPluginExtensionPoint[]
  depends_on?: string[]
  optionally_depends_on?: string[]
  conflicts_with?: string[]
  dependents?: string[]
  health?: { state: string; reasons: string[] }
  links?: AdminPluginLink[]
  config_schema?: Array<{ key: string; label?: string; type: string; description?: string; env_var?: string; default?: unknown }>
  config?: Record<string, unknown>
}

export type AdminPluginDetail = AdminPlugin & {
  docs: AdminPluginDoc[]
  metrics: AdminPluginMetric[]
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
  return getJson<AdminPluginDetail>(`/api/v1/app/admin/plugins/${encodeURIComponent(name)}`)
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
