import { getJson } from "./client"

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
  name: string
  version: string
  enabled: boolean
  description: string | null
  homepage: string | null
  author: string | null
  source: string | null
  extension_points: AdminPluginExtensionPoint[]
}

export type AdminPluginsPayload = {
  plugins: AdminPlugin[]
}

export function fetchAdminPlugins() {
  return getJson<AdminPluginsPayload>("/api/v1/app/admin/plugins")
}
