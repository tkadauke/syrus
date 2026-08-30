import { getJson } from "./client"

export type SidebarPluginPage = {
  id: string
  label: string
  label_key?: string | null
  path: string
  paths: string[]
  order: number
  component?: string | null
  icon?: string | null
  smart_folder_api_path?: string | null
  smart_folder_subject?: string | null
}

export type SidebarPluginPagesPayload = {
  pages: SidebarPluginPage[]
}

export function fetchSidebarPluginPages() {
  return getJson<SidebarPluginPagesPayload>("/api/v1/app/sidebar_pages")
}
