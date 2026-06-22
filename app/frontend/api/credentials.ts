import { deleteJson, getJson, patchJson, postForm, postJson } from "./client"

export type CredentialsUser = {
  id: number
  email_address: string
  name: string | null
  first_name: string | null
  last_name: string | null
  profile_location: string | null
  profile_company: string | null
  profile_website: string | null
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

export type CredentialTestResult = {
  credential: string
  ok: boolean
  message: string
  details: {
    login?: string
    scopes?: string[]
    accepted_scopes?: string[]
    missing_scopes?: string[]
  }
}

export type CredentialTestPayload = {
  credential_test: CredentialTestResult
  message?: string
}

export type PersonalDocumentsPayload = {
  documents: PersonalDocument[]
  message?: string
}

export type CredentialsInput = {
  name: string
  first_name: string
  last_name: string
  profile_location: string
  profile_company: string
  profile_website: string
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

// Saves only the GitHub token. The credentials controller updates just the
// keys present in the payload, so this leaves every other profile/credential
// field untouched — used by the onboarding "Configure GitHub" modal.
export function saveGithubToken(githubToken: string) {
  return patchJson<CredentialsPayload>("/api/v1/app/credentials", {
    user: { github_token: githubToken }
  })
}

export function clearCredential(credential: string) {
  return postJson<CredentialsPayload>("/api/v1/app/credentials/clear_credential", {
    credential
  })
}

export function testCredential(credential: string) {
  return postJson<CredentialTestPayload>("/api/v1/app/credentials/test_credential", {
    credential
  })
}

// Probe a pasted-but-unsaved GitHub token: reports whether it authenticates
// and whether it carries the repo + workflow scopes Syrus requires.
export function testGithubToken(githubToken: string) {
  return postJson<CredentialTestPayload>("/api/v1/app/credentials/test_github_token", {
    github_token: githubToken
  })
}

// Preflight: does `claude --print` already work on this machine using the
// operator's local Claude login? Lets the wizard skip token setup entirely.
export function testClaudeCli() {
  return postJson<CredentialTestPayload>("/api/v1/app/credentials/test_claude_cli")
}

export type ClaudeOauthStart = { authorize_url: string }
export type CodexOauthStart = { authorize_url: string; listener_started: boolean }

// Begin the Claude subscription OAuth flow; returns the authorize URL the
// modal opens. The provider shows a code to paste back.
export function startClaudeOauth() {
  return postJson<ClaudeOauthStart>("/api/v1/app/credentials/claude_oauth_start")
}

// Finish the Claude OAuth flow by exchanging the pasted code (raw or the
// `code#state` form). Saves + tests the token; returns the test result.
export function exchangeClaudeOauth(code: string) {
  return postJson<CredentialTestPayload>("/api/v1/app/credentials/claude_oauth_exchange", {
    code
  })
}

export function startCodexOauth() {
  return postJson<CodexOauthStart>("/api/v1/app/credentials/codex_oauth_start")
}

export function exchangeCodexOauth(code: string) {
  return postJson<CredentialTestPayload>("/api/v1/app/credentials/codex_oauth_exchange", {
    code
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
