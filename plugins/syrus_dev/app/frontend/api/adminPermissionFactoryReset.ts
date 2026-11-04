import { postJson } from "@app/api/client"

export const permissionResetScopes = ["chat", "actor", "user", "repository", "instance"] as const
export type PermissionResetScope = (typeof permissionResetScopes)[number]

export type PermissionResetPreview = {
  scope_type: PermissionResetScope
  scope_id: string | null
  default_version: string
  counts: Record<string, number>
  confirmation_digest: string
  retained_data: string[]
  instance_confirmation: string | null
}

export type PermissionResetResult = {
  outcome: "succeeded"
  changed: boolean
  counts: Record<string, number>
  audit: { id: number; completed_at: string; default_version: string }
}

export function previewPermissionFactoryReset(scopeType: PermissionResetScope, scopeId: string) {
  return postJson<PermissionResetPreview>("/api/v1/app/admin/permission_factory_resets/preview", {
    scope_type: scopeType,
    scope_id: scopeType === "instance" ? null : scopeId
  })
}

export function applyPermissionFactoryReset(preview: PermissionResetPreview, typedConfirmation: string) {
  return postJson<PermissionResetResult>("/api/v1/app/admin/permission_factory_resets", {
    scope_type: preview.scope_type,
    scope_id: preview.scope_id,
    confirmation_digest: preview.confirmation_digest,
    typed_confirmation: typedConfirmation
  })
}
