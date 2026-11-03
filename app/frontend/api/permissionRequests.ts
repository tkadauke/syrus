import { deleteJson, getJson, postJson } from "./client"

export type SmartPermissionKind = "always_allow_similar" | "allow_job" | "allow_chat"
export type SmartPermissionOption = {
  kind: SmartPermissionKind
  duration: "permanent" | "job" | "chat_session"
  digest: string
  summary: { allows: string[]; excludes: string[] }
  draft: Record<string, unknown>
  ceiling: Record<string, unknown>
  context: {
    coworker: string | null
    operation: string | null
    repository: string | null
    resource_scope_label: string | null
    duration: string
  }
}
export type PermissionAuthorityReference = { kind: string; id: number }

export type PermissionRequestReference = { type: string; id: number; label: string }
export type PermissionRequestItem = {
  id: number
  kind: string
  state: string
  capability: string
  operation: string | null
  resource_type: string
  resource_scope: Record<string, unknown>
  arguments: Record<string, unknown>
  effects: string[]
  risk: string | null
  purpose: string | null
  policy_chain: Array<Record<string, unknown>>
  decisive_rule: Record<string, unknown>
  requested_durations: string[]
  selected_duration: string | null
  decision_reason: string | null
  decided_at: string | null
  prerequisite_ids?: number[]
  smart_option?: SmartPermissionOption | null
  resulting_authority?: PermissionAuthorityReference | null
}
export type PermissionRequest = {
  id: number
  state: string
  actionable: boolean
  purpose: string | null
  requested_by: string
  runtime_role: string | null
  created_at: string
  checkpoint_state: string | null
  non_actionable_reason: string | null
  origin: PermissionRequestReference | null
  subject: PermissionRequestReference | null
  repository: PermissionRequestReference | null
  items: PermissionRequestItem[]
}

export type PermissionRequestsPayload = {
  requests: PermissionRequest[]
  summary: { pending_count: number; blocked_agent_count: number }
  pagination: { page: number; per_page: number; total: number; total_pages: number }
}
export const fetchPermissionRequests = (page = 1) => {
  return getJson<PermissionRequestsPayload>(`/api/v1/app/permission_requests?page=${page}`)
}
export const decidePermissionRequest = (id: number, decision: "approved" | "denied", duration?: string) =>
  postJson<{ request: PermissionRequest }>(`/api/v1/app/permission_requests/${id}/decide`, { decision, duration })
export const dismissPermissionRequest = (id: number) => {
  return deleteJson<{ request: PermissionRequest }>(`/api/v1/app/permission_requests/${id}`)
}
export const batchDecidePermissionRequests = (requestIds: number[], decision: "approved" | "denied", duration?: string) =>
  postJson<{ requests: PermissionRequest[] }>("/api/v1/app/permission_requests/batch_decide", { request_ids: requestIds, decision, duration })
export const smartDecidePermissionRequest = (id: number, itemId: number, option: Pick<SmartPermissionOption, "duration" | "digest">) =>
  postJson<{ request: PermissionRequest }>(`/api/v1/app/permission_requests/${id}/items/${itemId}/smart_decision`, {
    duration: option.duration,
    digest: option.digest
  })
