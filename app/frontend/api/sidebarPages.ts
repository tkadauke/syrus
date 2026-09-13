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
  /** Endpoint returning {"count": n}; polled to badge the nav entry. */
  badge_api_path?: string | null
}

export type SidebarPluginPagesPayload = {
  pages: SidebarPluginPage[]
}

export async function fetchSidebarPluginPages() {
  try {
    const payload = await getJson<SidebarPluginPagesPayload>("/api/v1/app/sidebar_pages")
    return Array.isArray(payload.pages) ? payload : { pages: [] }
  } catch {
    return { pages: [] }
  }
}
