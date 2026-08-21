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
  paths: {
    app_memory_path: string
    app_publish_path: string
    app_audit_events_path: string
  }
}

export type MemoryAuditEventActor =
  | { kind: "user"; id: number | null; name: string | null }
  | { kind: "agent"; run_id: number | null }
  | { kind: "system" }

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
  deleted: boolean
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

export function fetchMemoryAuditEvents(path: string) {
  return getJson<MemoryAuditEventsPayload>(path)
}
