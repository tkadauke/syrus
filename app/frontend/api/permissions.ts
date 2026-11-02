import { getJson, postJson } from "./client"

export type PermissionRule = {
  id: number
  policy: "allow" | "deny" | "ask"
  capability: string
  operation: string | null
  subject_selector_type: string
  subject_selector_id: string | null
  resource_scope: Record<string, unknown>
  rationale: string | null
  revoked_at: string | null
  editable: boolean
  owner: { kind: string; id?: number; name: string }
}

export type InheritedPermission = {
  capability: string
  operation: string
  effects: string[]
  risk: string
  defaults: Record<string, string>
  requestable_roles: string[]
  authority_durations: string[]
  owner: { kind: string; name: string }
  editable: false
  explanation: string
}

export type PermissionsPayload = { rules: PermissionRule[]; inherited: InheritedPermission[] }

export const fetchPermissions = () => getJson<PermissionsPayload>("/api/v1/app/permission_rules")
export const createPermissionRule = (permission_rule: Record<string, unknown>) =>
  postJson<{ rule: PermissionRule }>("/api/v1/app/permission_rules", { permission_rule })
export const revokePermissionRule = (id: number) => postJson<{ rule: PermissionRule }>(`/api/v1/app/permission_rules/${id}/revoke`)
