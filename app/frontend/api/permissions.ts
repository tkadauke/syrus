import { getJson, patchJson, postJson } from "./client"

export type PermissionRule = {
  id: number
  policy: "allow" | "deny" | "ask"
  capability: string
  operation: string | null
  subject_selector_type: string
  subject_selector_id: string | null
  resource_scope: Record<string, unknown>
  resource_type: string
  resource_scope_label: string
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
  presets: Array<{ name: string; policy?: string; [key: string]: unknown }>
  owner: { kind: string; name: string }
  editable: false
  explanation: string
}

export type PermissionsPayload = { rules: PermissionRule[]; inherited: InheritedPermission[] }

export const fetchPermissions = () => getJson<PermissionsPayload>("/api/v1/app/permission_rules")
export const createPermissionRule = (permission_rule: Record<string, unknown>) =>
  postJson<{ rule: PermissionRule }>("/api/v1/app/permission_rules", { permission_rule })
export const updatePermissionRule = (id: number, permission_rule: Record<string, unknown>) =>
  patchJson<{ rule: PermissionRule }>(`/api/v1/app/permission_rules/${id}`, { permission_rule })
export const applyPermissionPreset = (permission_rule: Record<string, unknown>) =>
  postJson<{ rule: PermissionRule }>("/api/v1/app/permission_rules/apply_preset", { permission_rule })
export const revokePermissionRule = (id: number) => postJson<{ rule: PermissionRule }>(`/api/v1/app/permission_rules/${id}/revoke`)
export type PermissionBulkOperation = Record<string, unknown> & { action: "grant" | "revoke" }
export type PermissionPreview = { action: string; policy: string; subject: string; capability: string; operation: string; resource_scope_label: string }
export const previewPermissionBulk = (operations: PermissionBulkOperation[]) =>
  postJson<{ preview: PermissionPreview[]; confirmation_digest: string }>("/api/v1/app/permission_rules/preview_bulk", { operations })
export const applyPermissionBulk = (operations: PermissionBulkOperation[], confirmation_digest: string) =>
  postJson<{ rules: PermissionRule[] }>("/api/v1/app/permission_rules/bulk", { operations, confirmation_digest })
