import { deleteJson, patchJson } from "./client"

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
}

export type SmartFolderInput = {
  name: string
  position: number
}

export function updateSmartFolder(id: number, values: SmartFolderInput) {
  return patchJson<SmartFolderMutationPayload>(`/api/v1/app/smart_folders/${id}`, {
    smart_folder: values
  })
}

export function deleteSmartFolder(id: number) {
  return deleteJson<SmartFolderMutationPayload>(`/api/v1/app/smart_folders/${id}`)
}
