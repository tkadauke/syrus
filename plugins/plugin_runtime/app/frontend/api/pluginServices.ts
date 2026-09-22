import { getJson, postJson } from "@app/api/client"

export type PluginServiceAction = "stop" | "start" | "restart" | "logs"

export type PluginService = {
  service: string
  plugin: string | null
  state: string
  endpoint?: string | null
  image?: string | null
  error?: string | null
  container_id?: string | null
  checked_at?: string | null
  desired: boolean
  held: boolean
  actions: PluginServiceAction[]
}

export type PluginServicesPayload = {
  mode: "managed" | "external"
  manageable: boolean
  manager_error: string | null
  services: PluginService[]
}

const BASE = "/api/v1/app/admin/plugin_services"

export function fetchPluginServices() {
  return getJson<PluginServicesPayload>(BASE)
}

export function runPluginServiceAction(name: string, action: Exclude<PluginServiceAction, "logs">) {
  return postJson<{ service: PluginService }>(`${BASE}/${encodeURIComponent(name)}/${action}`)
}

export function fetchPluginServiceLogs(name: string, tail: number) {
  return getJson<{ service: string; logs: string }>(`${BASE}/${encodeURIComponent(name)}/logs?tail=${tail}`)
}
