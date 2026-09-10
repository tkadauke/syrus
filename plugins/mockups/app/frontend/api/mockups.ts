import { getJson, patchJson } from "@app/api/client"
import type { ChatPreviewPanelVisibility, PreviewPanelPayload } from "@app/api/chats"
import type { FilterSchemaField } from "@app/components/FilterBar"

export type MockupSummary = {
  id: number
  slug: string
  title: string
  preview_panel_id: number
  chat_session_id: number | null
  chat_path: string | null
  entry_viewer_kind: string
  file_count: number
  published_at: string | null
  updated_at: string | null
  app_path: string
}

// The same panel shape the chat sidebar renders, pointed at the
// chat-independent /api/v1/app/preview_panels routes.
export type MockupPanel = PreviewPanelPayload & {
  state: string
  updated_at: string | null
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

export function updateMockupPanelVisibility(path: string, visibility: ChatPreviewPanelVisibility): Promise<MockupPanel> {
  return patchJson<MockupPanel>(path, { visibility })
}
