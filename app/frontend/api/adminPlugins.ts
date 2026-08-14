import { getJson, postJson } from "./client"

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
  description: string | null
  homepage: string | null
  author: string | null
  source: string | null
  extension_points: AdminPluginExtensionPoint[]
}

export type AdminPluginsPayload = {
  plugins: AdminPlugin[]
}

export function fetchAdminPlugins(query = "") {
  const params = new URLSearchParams()
  if (query.trim()) params.set("q", query.trim())
  const search = params.toString()
  return getJson<AdminPluginsPayload>(`/api/v1/app/admin/plugins${search ? `?${search}` : ""}`)
}

export function enableAdminPlugin(name: string) {
  return postJson<AdminPluginsPayload>(`/api/v1/app/admin/plugins/${encodeURIComponent(name)}/enable`)
}

export function disableAdminPlugin(name: string) {
  return postJson<AdminPluginsPayload>(`/api/v1/app/admin/plugins/${encodeURIComponent(name)}/disable`)
}
