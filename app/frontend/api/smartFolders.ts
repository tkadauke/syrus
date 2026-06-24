import { deleteJson, getJson, patchJson } from "./client"

export type SmartFolderRow = {
  id: number
  name: string
  position: number
  filter: Record<string, unknown>
}

export type SmartFoldersPayload = {
  subject_type: string
  subject_label: string
  dashboard_path: string
  smart_folders: SmartFolderRow[]
  message?: string
}

export type SmartFolderInput = {
  name: string
  position: number
  filter?: Record<string, unknown>
}

export function fetchSmartFolders(search: string) {
  return getJson<SmartFoldersPayload>(`/api/v1/app/smart_folders${search}`)
}

export function updateSmartFolder(id: number, values: SmartFolderInput) {
  const { filter, ...smartFolder } = values

  return patchJson<SmartFoldersPayload>(`/api/v1/app/smart_folders/${id}`, {
    ...(filter === undefined ? {} : { filter: JSON.stringify(filter) }),
    smart_folder: smartFolder
  })
}

export function deleteSmartFolder(id: number) {
  return deleteJson<SmartFoldersPayload>(`/api/v1/app/smart_folders/${id}`)
}
