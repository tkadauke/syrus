import { getJson } from "@app/api/client"
import type { FilterSchemaField } from "@app/components/FilterBar"

export type MockupSummary = {
  id: number
  slug: string
  title: string
  preview_panel_id: number
  chat_session_id: number | null
  entry_viewer_kind: string
  file_count: number
  published_at: string | null
  updated_at: string | null
  app_path: string
}

export type MockupPanelVersion = {
  id: number
  created_at: string
  entry_path: string
  entry_content_type: string
  entry_viewer_kind: string
}

// The same panel shape the chat sidebar renders, pointed at the
// chat-independent /api/v1/app/preview_panels routes.
export type MockupPanel = {
  id: number
  title: string
  state: string
  visibility: string
  file_count: number
  url: string
  app_export_path: string
  app_file_base_path: string
  app_token_path: string
  current_version_id: number | null
  entry_path: string
  entry_content_type: string
  entry_viewer_kind: string
  updated_at: string | null
  versions: MockupPanelVersion[]
}

export type MockupsIndexPayload = {
  mockups: MockupSummary[]
  filter: Record<string, unknown> | null
  filter_schema: FilterSchemaField[]
  pagination: { page: number; per_page: number; total: number; has_next_page: boolean; has_previous_page: boolean }
}

export type MockupDetailPayload = {
  mockup: MockupSummary
  panel: MockupPanel
}

export function fetchMockups(search: string): Promise<MockupsIndexPayload> {
  const query = search && search !== "?" ? search : ""
  return getJson<MockupsIndexPayload>(`/api/v1/app/mockups${query}`)
}

export function fetchMockup(ref: string): Promise<MockupDetailPayload> {
  return getJson<MockupDetailPayload>(`/api/v1/app/mockups/${encodeURIComponent(ref)}`)
}
