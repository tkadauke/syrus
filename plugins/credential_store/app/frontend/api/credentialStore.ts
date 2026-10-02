import { deleteJson, getJson, patchJson, postJson } from "@app/api/client"

export type CredentialStoreOption = {
  id: number
  label: string
  detail?: string | null
}

export type CredentialStoreTypeOption = {
  name: string
  label: string
  description?: string
  plugin?: string
}

export type CredentialStoreCredential = {
  id: number
  name: string
  description: string | null
  credential_type: string
  scope_type: "user" | "repository" | "team" | "instance"
  scope_id: number | null
  scope_label: string | null
  safe_metadata: Record<string, unknown>
  target_constraints: Record<string, unknown>
  allowed_surfaces: string[]
  allowed_tools: string[]
  expires_at: string | null
  last_rotated_at: string | null
  revoked_at: string | null
  active: boolean
  can_manage: boolean
  created_by: { id: number; display_name: string; email_address: string } | null
  owner_user: { id: number; display_name: string; email_address: string } | null
  last_access: {
    id: number
    surface: string
    action: string
    result: string
    tool_name: string | null
    purpose: string | null
    denial_reason: string | null
    created_at: string
  } | null
  created_at: string
  updated_at: string
}

export type CredentialStorePayload = {
  credentials: CredentialStoreCredential[]
  options: {
    credential_types: CredentialStoreTypeOption[]
    scopes: Array<{ value: CredentialStoreCredential["scope_type"]; label: string }>
    safe_metadata_keys: string[]
    target_constraint_keys: string[]
    users: CredentialStoreOption[]
    repositories: CredentialStoreOption[]
    teams: CredentialStoreOption[]
  }
  message?: string
}

export type CredentialStoreInput = {
  name: string
  description: string
  credential_type: string
  scope_type: CredentialStoreCredential["scope_type"]
  scope_id: number | null
  payload?: string
  safe_metadata: Record<string, unknown>
  target_constraints: Record<string, unknown>
  allowed_surfaces: string[]
  allowed_tools: string[]
  expires_at: string | null
}

const BASE = "/api/v1/app/credential_store/credentials"

export function fetchCredentialStore() {
  return getJson<CredentialStorePayload>(BASE)
}

export function createCredentialStoreCredential(input: CredentialStoreInput) {
  return postJson<CredentialStorePayload>(BASE, { credential: input })
}

export function updateCredentialStoreCredential(id: number, input: CredentialStoreInput) {
  return patchJson<CredentialStorePayload>(`${BASE}/${id}`, { credential: input })
}

export function rotateCredentialStoreCredential(id: number, payload: string) {
  return postJson<CredentialStorePayload>(`${BASE}/${id}/rotate`, { credential: { payload } })
}

export function revokeCredentialStoreCredential(id: number) {
  return postJson<CredentialStorePayload>(`${BASE}/${id}/revoke`, {})
}

export function deleteCredentialStoreCredential(id: number) {
  return deleteJson<CredentialStorePayload>(`${BASE}/${id}`)
}
