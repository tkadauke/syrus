import { deleteJson, getJson, postJson } from "@app/api/client"

export type PluginServiceAction = "stop" | "start" | "restart" | "logs" | "details"

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
  privileged?: boolean
  actions: PluginServiceAction[]
}

export type PluginServiceVolume = {
  name: string
  service: string | null
  plugin: string | null
  in_use: boolean
  size_bytes?: number | null
}

export type PluginServicesPayload = {
  mode: "managed" | "external"
  manageable: boolean
  manager_error: string | null
  services: PluginService[]
  volumes: PluginServiceVolume[]
}

const BASE = "/api/v1/app/admin/plugin_services"

export function fetchPluginServices() {
  return getJson<PluginServicesPayload>(BASE)
}

export function runPluginServiceAction(name: string, action: "stop" | "start" | "restart") {
  return postJson<{ service: PluginService }>(`${BASE}/${encodeURIComponent(name)}/${action}`)
}

export function fetchPluginServiceLogs(name: string, tail: number) {
  return getJson<{ service: string; logs: string }>(`${BASE}/${encodeURIComponent(name)}/logs?tail=${tail}`)
}

export function deletePluginServiceVolume(name: string) {
  return deleteJson<void>(`${BASE}/volumes/${encodeURIComponent(name)}`)
}

export type DetailFormat = "number" | "bytes" | "time" | "text"

export type PluginServiceDetails = {
  summary: { label_key: string; value: string | number | null; format: DetailFormat }[]
  table?: {
    columns: { key: string; label_key: string; format: DetailFormat }[]
    rows: Record<string, string | number | null>[]
  }
}

export function fetchPluginServiceDetails(name: string) {
  return getJson<{ service: string; details: PluginServiceDetails }>(`${BASE}/${encodeURIComponent(name)}/details`)
}
