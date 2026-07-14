import { deleteJson, getJson, patchJson, postJson } from "./client"
import type { FilterSchemaField } from "../components/FilterBar"

export type MemoryKind = "user_pref" | "project_fact" | "feedback" | "reference" | "decision"
export type MemoryScope = "global" | "repository"

export type MemoryRow = {
  id: number
  kind: MemoryKind
  scope: MemoryScope
  scope_id: number | null
  repository_name: string | null
  content: string
  published: boolean
  created_at: string
  updated_at: string
  owner: {
    id: number
    name: string
  }
  permissions: {
    can_manage: boolean
    can_publish: boolean
  }
  paths: {
    app_memory_path: string
    app_publish_path: string
  }
}

export type MemoryRepository = {
  id: number
  name: string
}

export type MemoriesPayload = {
  memories: MemoryRow[]
  kinds: MemoryKind[]
  scopes: MemoryScope[]
  repositories: MemoryRepository[]
  filter: Record<string, unknown>
  controls: {
    filter_schema: FilterSchemaField[]
  }
  current_user: {
    id: number
    admin: boolean
  }
  pagination: {
    page: number
    per_page: number
    total: number
    total_pages: number
  }
  message?: string
}

export type MemoryInput = {
  content: string
  kind: MemoryKind
  scope: MemoryScope
  scope_id?: number | null
}

export type MemoryUpdateInput = {
  content?: string
  kind?: MemoryKind
  scope?: MemoryScope
  scope_id?: number | null
}

export function fetchMemories(search: string) {
  return getJson<MemoriesPayload>(`/api/v1/app/memories${search}`)
}

export function createMemory(values: MemoryInput) {
  return postJson<MemoriesPayload>("/api/v1/app/memories", { memory: values })
}

export function updateMemory(path: string, values: MemoryUpdateInput) {
  return patchJson<MemoriesPayload>(path, { memory: values })
}

export function deleteMemory(path: string) {
  return deleteJson<MemoriesPayload>(path)
}

export function publishMemory(path: string) {
  return postJson<MemoriesPayload>(path)
}

export function unpublishMemory(path: string) {
  return deleteJson<MemoriesPayload>(path)
}
