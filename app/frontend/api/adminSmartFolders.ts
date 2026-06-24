import type { FilterSchemaField } from "../components/FilterBar"

export type AdminSmartFolder = {
  id: number
  name: string
  kind: string
  subject_type: string
  visibility: string
  count: number
  active: boolean
  filter?: Record<string, unknown>
  path: string
}

export type AdminSmartFolderPayload = {
  active_smart_folder_id: number | null
  smart_folders: AdminSmartFolder[]
}

export type AdminFilterControls = {
  filter_schema: FilterSchemaField[]
}

export type AdminFilteredPayload = AdminSmartFolderPayload & {
  filter: Record<string, unknown>
  controls: AdminFilterControls
}
