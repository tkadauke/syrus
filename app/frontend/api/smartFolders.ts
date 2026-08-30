import { deleteJson, getJson, patchJson, postJson } from "./client"
import type { AdminSmartFolder } from "./adminSmartFolders"

export type SmartFolderRow = {
  id: number
  name: string
  position: number
  filter: Record<string, unknown>
}

type SmartFolderMutationPayload = {
  subject_type: string
  subject_label: string
  dashboard_path: string
  smart_folders: SmartFolderRow[]
  message?: string
  redirect_to?: string
}

export type SmartFolderInput = {
  name: string
  position: number
  filter?: Record<string, unknown>
}

export type SmartFolderCreateInput = {
  name: string
  subjectType: string
  filter: Record<string, unknown>
}

export function updateSmartFolder(id: number, values: SmartFolderInput) {
  const { filter, ...smartFolder } = values

  return patchJson<SmartFolderMutationPayload>(`/api/v1/app/smart_folders/${id}`, {
    ...(filter === undefined ? {} : { filter: JSON.stringify(filter) }),
    smart_folder: smartFolder
  })
}

export function createSmartFolder(values: SmartFolderCreateInput) {
  return postJson<SmartFolderMutationPayload>("/api/v1/app/smart_folders", {
    filter: JSON.stringify(values.filter),
    subject_type: values.subjectType,
    smart_folder: { name: values.name }
  })
}

export function deleteSmartFolder(id: number) {
  return deleteJson<SmartFolderMutationPayload>(`/api/v1/app/smart_folders/${id}`)
}

export type SmartFolderNavigationPayload = {
  active_smart_folder_id: number | null
  filter: Record<string, unknown>
  smart_folders: AdminSmartFolder[]
}

export function fetchSmartFolderNavigation(apiPath: string, search = "") {
  return getJson<SmartFolderNavigationPayload>(`${apiPath}${search}`)
}
