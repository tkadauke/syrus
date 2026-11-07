import { deleteJson, getJson, patchJson, postJson } from "@app/api/client"
import type { FilterSchemaField } from "@app/components/FilterBar"

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
  changed: boolean
  deleted_at: string | null
  deleted_by: { id: number; name: string } | null
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
}

export type MemoryAuditEventActor = { kind: "user"; id: number | null; name: string | null } | { kind: "agent"; run_id: number | null } | { kind: "system" }

export type MemoryAuditEvent = {
  id: number
  event_type: "created" | "updated" | "deleted"
  actor: MemoryAuditEventActor
  previous: { content: string | null; kind: MemoryKind | null; confidence: number | null }
  new: { content: string | null; kind: MemoryKind | null; confidence: number | null }
  created_at: string
}

export type MemoryAuditEventsPayload = {
  memory_id: number
  audit_events: MemoryAuditEvent[]
  next_cursor: number | null
}

export type MemoryMutationPayload = { message?: string; memory?: MemoryRow }

export type MemoryRepository = {
  id: number
  name: string
}

export type MemoriesMetadata = {
  kinds: MemoryKind[]
  scopes: MemoryScope[]
  repositories: MemoryRepository[]
  controls: { filter_schema: FilterSchemaField[] }
}

export type MemoriesPagePayload = {
  memories: MemoryRow[]
  filter: Record<string, unknown>
  deleted: boolean
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

export type MemoriesPayload = MemoriesPagePayload & MemoriesMetadata

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
  return getJson<MemoriesPagePayload>(`/api/v1/app/memories${search}`)
}

export function fetchMemoriesMetadata() {
  return getJson<MemoriesMetadata>("/api/v1/app/memories/metadata")
}

export function createMemory(values: MemoryInput) {
  return postJson<MemoryMutationPayload>("/api/v1/app/memories", { memory: values })
}

export function updateMemory(id: number, values: MemoryUpdateInput) {
  return patchJson<MemoryMutationPayload>(`/api/v1/app/memories/${id}`, { memory: values })
}

export function deleteMemory(id: number) {
  return deleteJson<MemoryMutationPayload>(`/api/v1/app/memories/${id}`)
}

export function publishMemory(id: number) {
  return postJson<MemoryMutationPayload>(`/api/v1/app/memories/${id}/publish`)
}

export function unpublishMemory(id: number) {
  return deleteJson<MemoryMutationPayload>(`/api/v1/app/memories/${id}/publish`)
}

export function fetchMemoryAuditEvents(id: number, before?: number) {
  const cursor = before ? `?before=${before}` : ""
  return getJson<MemoryAuditEventsPayload>(`/api/v1/app/memories/${id}/audit_events${cursor}`)
}
