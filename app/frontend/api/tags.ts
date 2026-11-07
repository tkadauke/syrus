import { deleteJson, getJson, patchJson, postJson } from "./client"

export type TagPaletteColor = {
  key: string
  label: string
  bg: string
  text: string
}

export type TagRow = {
  id: number
  name: string
  color: string
  jobs_count: number
  created_at: string
  updated_at: string
}

export type TagsPayload = {
  palette: TagPaletteColor[]
  tags: TagRow[]
  message?: string
}

export type TagMutationPayload = { tag: TagRow; message?: string }
export type TagDeletePayload = { deleted_id: number; message?: string }

export type TagInput = {
  name: string
  color: string
}

export function fetchTags() {
  return getJson<TagsPayload>("/api/v1/app/tags")
}

export function createTag(values: TagInput) {
  return postJson<TagMutationPayload>("/api/v1/app/tags", { tag: values })
}

export function updateTag(id: number, values: TagInput) {
  return patchJson<TagMutationPayload>(`/api/v1/app/tags/${id}`, { tag: values })
}

export function deleteTag(id: number) {
  return deleteJson<TagDeletePayload>(`/api/v1/app/tags/${id}`)
}
