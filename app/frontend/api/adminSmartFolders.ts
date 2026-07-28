import type { FilterSchemaField } from "../components/FilterBar"
import { postJson } from "./client"

export type AdminSmartFolder = {
  id: number
  name: string
  key: string | null
  position: number
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

export type CreateAdminSmartFolderInput = {
  name: string
  subjectType: string
  filters: Record<string, string>
}

export type CreateAdminSmartFolderResult = {
  message: string
  redirect_to: string
  smart_folder: AdminSmartFolder
}

export function createAdminSmartFolder({ name, subjectType, filters }: CreateAdminSmartFolderInput) {
  return postJson<CreateAdminSmartFolderResult>("/api/v1/app/smart_folders", {
    smart_folder: { name, position: 0 },
    subject_type: subjectType,
    ...filters
  })
}
