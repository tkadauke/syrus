import { deleteJson, getJson, postJson } from "./client"

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

export const fetchPermissionRequests = () => getJson<{ requests: PermissionRequest[] }>("/api/v1/app/permission_requests")
export const decidePermissionRequest = (id: number, decision: "approved" | "denied", duration?: string) =>
  postJson<{ request: PermissionRequest }>(`/api/v1/app/permission_requests/${id}/decide`, { decision, duration })
export const dismissPermissionRequest = (id: number) => deleteJson<{ request: PermissionRequest }>(`/api/v1/app/permission_requests/${id}`)
