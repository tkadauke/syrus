import { deleteJson, getJson, patchJson, postForm, postJson } from "./client"

export type CredentialsUser = {
  id: number
  email_address: string
  name: string | null
  first_name: string | null
  last_name: string | null
  display_name: string
  github_handle: string | null
  profile_bio: string | null
  avatar_url: string | null
  admin: boolean
  agent_provider: string
  codex_auth_mode: string
  agent_max_turns: number
  scheduling_paused: boolean
  auto_approve_mode: string
}

export type CredentialStatus = {
  github_token: boolean
  claude_oauth_token: boolean
  codex_api_key: boolean
  codex_auth_json: boolean
  api_token: boolean | null
}

export type GithubRateLimit = {
  remaining: number | null
  limit: number | null
  resource: string
  reset_at: string | null
  observed_at: string | null
}

export type PersonalDocument = {
  id: number
  kind: string
  google_doc_url: string | null
  filename: string | null
  content_type: string | null
  byte_size: number | null
  created_at: string
}

export type CredentialsOptions = {
  agent_providers: string[]
  codex_auth_modes: string[]
  agent_max_turns: {
    min: number
    max: number
  }
  clearable_credentials: Array<{
    value: string
    label: string
  }>
  auto_approve_modes: Array<{
    value: string
    label: string
    preview: string
  }>
}

export type CredentialsPayload = {
  user: CredentialsUser
  credential_status: CredentialStatus
  github_rate_limit: GithubRateLimit | null
  options: CredentialsOptions
  message?: string
  new_api_token?: string
}

export type PersonalDocumentsPayload = {
  documents: PersonalDocument[]
  message?: string
}

export type CredentialsInput = {
  name: string
  first_name: string
  last_name: string
  github_handle: string
  profile_bio: string
  avatar_url: string
  agent_provider: string
  claude_oauth_token: string
  codex_auth_mode: string
  codex_api_key: string
  codex_auth_json: string
  github_token: string
  agent_max_turns: number
  scheduling_paused: boolean
  auto_approve_mode: string
}

export function fetchCredentials() {
  return getJson<CredentialsPayload>("/api/v1/app/credentials")
}

export function fetchCredentialDocuments() {
  return getJson<PersonalDocumentsPayload>("/api/v1/app/credentials/documents")
}

export function updateCredentials(values: CredentialsInput) {
  return patchJson<CredentialsPayload>("/api/v1/app/credentials", {
    user: values
  })
}

export function clearCredential(credential: string) {
  return postJson<CredentialsPayload>("/api/v1/app/credentials/clear_credential", {
    credential
  })
}

export function rotateApiToken() {
  return postJson<CredentialsPayload>("/api/v1/app/credentials/rotate_api_token")
}

export function revokeApiToken() {
  return deleteJson<CredentialsPayload>("/api/v1/app/credentials/revoke_api_token")
}

export function addCredentialDocuments(files: File[], googleDocUrl: string) {
  const formData = new FormData()
  files.forEach((file) => formData.append("document[files][]", file))
  if (googleDocUrl.trim().length > 0) {
    formData.append("document[google_doc_url]", googleDocUrl.trim())
  }
  return postForm<PersonalDocumentsPayload>("/api/v1/app/credentials/documents", formData)
}

export function deleteCredentialDocument(id: number) {
  return deleteJson<PersonalDocumentsPayload>(`/api/v1/app/credentials/documents/${id}`)
}
