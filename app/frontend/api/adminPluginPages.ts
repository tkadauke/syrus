import { getJson } from "./client"

export type AdminPluginPage = {
  id: string
  label: string
  label_key?: string | null
  path: string
  paths: string[]
  order: number
  component?: string | null
  group_id?: string | null
}

export type AdminPluginPagesPayload = {
  pages: AdminPluginPage[]
}

export function fetchAdminPluginPages() {
  return getJson<AdminPluginPagesPayload>("/api/v1/app/admin/plugin_pages")
}
