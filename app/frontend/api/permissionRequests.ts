import { deleteJson, getJson, postJson } from "./client"

export type SmartPermissionKind = "always_allow_similar" | "always_allow_command" | "allow_job" | "allow_chat"
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
  /**
   * Present when this grant may stand for a family of invocations rather than
   * one exact call. `value` is a suggestion the operator edits; `full` is the
   * whole projected command, so the editor can check an edit is really a
   * prefix of it. Absent when the call cannot be widened safely.
   */
  prefix?: { field: string; value: string; full: string } | null
}
export type PermissionAuthorityReference = { kind: string; id: number }

export type PermissionRequestReference = { type: string; id: number; label: string }
export type PermissionPresentation = {
  statement?: string
  agent?: string
  origin?: string
  scope?: string
  consequences?: string[]
  why_approval_required?: string
  requested_durations?: string[]
}
export type PermissionRequestItem = {
  presentation?: PermissionPresentation
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
  smart_options?: SmartPermissionOption[]
  resulting_authority?: PermissionAuthorityReference | null
}
export type PermissionRequest = {
  presentation?: PermissionPresentation
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

export type PermissionFilterOption = { value: string; label: string }
export type PermissionFilterOptions = Record<"state" | "subject" | "action" | "effect" | "origin_type", PermissionFilterOption[]>
export type PermissionRequestsPayload = {
  requests: PermissionRequest[]
  filter_options?: PermissionFilterOptions
  summary: { pending_count: number; blocked_agent_count: number }
  pagination: { page: number; per_page: number; total: number; total_pages: number }
}
export type SlimPermissionRequest = Pick<PermissionRequest, "id" | "state" | "checkpoint_state">
export type MutationPermissionRequest = SlimPermissionRequest & Partial<Omit<PermissionRequest, keyof SlimPermissionRequest>>
export const fetchPermissionRequests = (page = 1, q = "", view?: "summary") => {
  const params = new URLSearchParams({ page: String(page) })
  if (q) params.set("q", q)
  if (view === "summary") {
    params.set("view", view)
    params.set("limit", "5")
  }
  return getJson<PermissionRequestsPayload>(`/api/v1/app/permission_requests?${params}`)
}
export const fetchPermissionRequestCount = () => {
  return getJson<Pick<PermissionRequestsPayload, "summary">>("/api/v1/app/permission_requests/count")
}
export const fetchPermissionRequest = (id: number) => {
  return getJson<{ request: PermissionRequest }>(`/api/v1/app/permission_requests/${id}`)
}
export const decidePermissionRequest = (id: number, decision: "approved" | "denied", duration?: string) =>
  postJson<{ request: MutationPermissionRequest }>(`/api/v1/app/permission_requests/${id}/decide`, { decision, duration })
export const dismissPermissionRequest = (id: number) => {
  return deleteJson<{ request: MutationPermissionRequest }>(`/api/v1/app/permission_requests/${id}`)
}
export const batchDecidePermissionRequests = (requestIds: number[], decision: "approved" | "denied", duration?: string) =>
  postJson<{ requests: MutationPermissionRequest[] }>("/api/v1/app/permission_requests/batch_decide", { request_ids: requestIds, decision, duration })
export const smartDecidePermissionRequest = (id: number, itemId: number, option: Pick<SmartPermissionOption, "duration" | "digest" | "prefix">) =>
  postJson<{ request: MutationPermissionRequest }>(`/api/v1/app/permission_requests/${id}/items/${itemId}/smart_decision`, {
    duration: option.duration,
    digest: option.digest,
    ...(option.prefix ? { prefix: option.prefix.value } : {})
  })
