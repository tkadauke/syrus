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
  /** "primary" (main sidebar nav) or "settings" (settings section side nav). */
  section?: string | null
  smart_folder_api_path?: string | null
  smart_folder_subject?: string | null
  /** Whether to also show the generic, unfiltered "All <label>" link above the page's own smart folders. Defaults to true. */
  smart_folder_all_link?: boolean
  /** Endpoint returning {"count": n}; polled to badge the nav entry. */
  badge_api_path?: string | null
}

export type SidebarPluginPagesPayload = {
  pages: SidebarPluginPage[]
}

export function fetchSidebarPluginPages() {
  return getJson<SidebarPluginPagesPayload>("/api/v1/app/sidebar_pages")
}
