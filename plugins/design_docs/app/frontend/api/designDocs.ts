import { getJson, patchJson, postJson } from "@app/api/client"
import type { AdminSmartFolder } from "@app/api/adminSmartFolders"
import type { FilterSchemaField } from "@app/components/filterBar/types"

export type DesignDocUser = {
  id: number
  name: string
  email_address: string
}

export type DesignDocRepository = {
  id: number
  slug: string
}

export type DesignDocSummary = {
  id: number
  display_id: string
  title: string
  visibility: "private" | "public"
  state: "draft" | "accepted" | "archived"
  owner: DesignDocUser | null
  repository_ids: number[]
  repositories: DesignDocRepository[]
  current_version_number: number | null
  origin_chat_session_id: number | null
  updated_at: string
  created_at: string
}

export type DesignDocAnchor = {
  id: number
  anchor_key: string
  marker_id: string
  anchor_kind: "point" | "range"
  status: string
  start_offset: number | null
  end_offset: number | null
  last_known_start_offset: number | null
  last_known_end_offset: number | null
  selected_markdown: string | null
  selected_text: string | null
  prefix_context: string | null
  suffix_context: string | null
}

export type DesignDocComment = {
  id: number
  author_kind: string
  author: DesignDocUser | null
  body: string
  created_at: string
  updated_at: string
}

export type DesignDocThread = {
  id: number
  state: "open" | "resolved"
  anchor: DesignDocAnchor
  opened_by: DesignDocUser | null
  resolved_by: DesignDocUser | null
  resolved_at: string | null
  comments: DesignDocComment[]
  created_at: string
  updated_at: string
}

export type DesignDocSuggestion = {
  id: number
  state: "pending" | "accepted" | "rejected" | "stale" | "conflict"
  suggested_by_kind: string
  suggested_by: DesignDocUser | null
  original_markdown: string
  suggested_markdown: string
  proposed_markdown: string
  change_type: "replace"
  change_summary: string | null
  base_version_id: number | null
  provenance: Record<string, unknown>
  conflict_reason: string | null
  anchor: DesignDocAnchor
  reviewed_by: DesignDocUser | null
  reviewed_at: string | null
  created_at: string
}

export type DesignDocDetail = DesignDocSummary & {
  markdown: string
  rendered_markdown: string
  collaborator_ids: number[]
  collaborators: DesignDocUser[]
  pending_suggestions_count: number
  open_threads_count: number
  threads: DesignDocThread[]
  suggestions: DesignDocSuggestion[]
}

export type DesignDocVersion = {
  id: number
  version_number: number
  markdown: string
  actor_kind: string
  actor: DesignDocUser | null
  change_summary: string | null
  metadata: Record<string, unknown>
  created_at: string
}

export type DesignDocsIndexPayload = {
  active_smart_folder_id: number | null
  filter: Record<string, unknown>
  filter_schema: FilterSchemaField[]
  smart_folders: AdminSmartFolder[]
  design_docs: DesignDocSummary[]
}

export type RepositoryDesignDocsPayload = DesignDocsIndexPayload & {
  repository: DesignDocRepository & { repository_path: string }
}

export type DesignDocDetailPayload = {
  design_doc: DesignDocDetail
  message?: string
}

export type DesignDocVersionsPayload = {
  design_doc: DesignDocSummary
  versions: DesignDocVersion[]
}

export type DesignDocWritePayload = DesignDocDetailPayload & {
  mode?: "canonical" | "suggestion"
  suggestion?: DesignDocSuggestion
  version?: DesignDocVersion
}

export type DesignDocInput = {
  title?: string
  markdown?: string
  visibility?: "private" | "public"
  state?: "draft" | "accepted" | "archived"
  change_summary?: string
  origin_chat_session_id?: number
  repository_ids?: number[]
  collaborator_user_ids?: number[]
  start_offset?: number
  end_offset?: number
  selected_markdown?: string
}

export function fetchDesignDocs(search = "") {
  return getJson<DesignDocsIndexPayload>(`/api/v1/app/design_docs${search}`)
}

export function fetchRepositoryDesignDocs(repositoryId: string | number, search = "") {
  return getJson<RepositoryDesignDocsPayload>(`/api/v1/app/repositories/${repositoryId}/design_docs${search}`)
}

export function fetchDesignDoc(id: string | number) {
  return getJson<DesignDocDetailPayload>(`/api/v1/app/design_docs/${id}`)
}

export function createDesignDoc(input: DesignDocInput) {
  return postJson<DesignDocWritePayload>("/api/v1/app/design_docs", { design_doc: input })
}

export function updateDesignDoc(id: string | number, input: DesignDocInput) {
  return patchJson<DesignDocWritePayload>(`/api/v1/app/design_docs/${id}`, { design_doc: input })
}

export function createDesignDocComment(id: string | number, input: { body: string; start_offset: number; end_offset: number; selected_markdown: string; selected_text?: string }) {
  return postJson<DesignDocWritePayload>(`/api/v1/app/design_docs/${id}/comments`, { comment: input })
}

export function createDesignDocSuggestion(id: string | number, input: { start_offset: number; end_offset: number; original_markdown: string; proposed_markdown: string; change_summary?: string; selected_text?: string }) {
  return postJson<DesignDocWritePayload>(`/api/v1/app/design_docs/${id}/suggestions`, { suggestion: { ...input, change_type: "replace" } })
}

export function resolveDesignDocThread(id: string | number, threadId: string | number) {
  return postJson<{ thread: DesignDocThread; message: string }>(`/api/v1/app/design_docs/${id}/threads/${threadId}/resolve`)
}

export function acceptDesignDocSuggestion(id: string | number, suggestionId: string | number) {
  return postJson<DesignDocWritePayload>(`/api/v1/app/design_docs/${id}/suggestions/${suggestionId}/accept`)
}

export function rejectDesignDocSuggestion(id: string | number, suggestionId: string | number) {
  return postJson<DesignDocWritePayload>(`/api/v1/app/design_docs/${id}/suggestions/${suggestionId}/reject`)
}

export function fetchDesignDocVersions(id: string | number) {
  return getJson<DesignDocVersionsPayload>(`/api/v1/app/design_docs/${id}/versions`)
}
