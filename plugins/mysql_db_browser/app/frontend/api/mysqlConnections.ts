import { deleteJson, getJson, patchJson, postJson } from "@app/api/client"

export type MysqlConnectionRow = {
  id: number
  label: string
  host: string
  port: number
  username: string
  default_database: string | null
  agentic_access_enabled: boolean
  allow_writes: boolean
  has_password: boolean
  credential_scope_type: CredentialScopeType | null
  credential_scope_id: number | null
  legacy_credentials: boolean
  created_at: string
  updated_at: string
}

export type MysqlConnectionInput = {
  label: string
  host: string
  port: number
  username: string
  default_database: string
  agentic_access_enabled: boolean
  allow_writes: boolean
  password?: string
  credential_scope_type: CredentialScopeType
  credential_scope_id?: number
}

export type CredentialScopeType = "user" | "repository" | "team" | "instance"
export type CredentialScopeOption = { value: CredentialScopeType; label: string }
export type CredentialScopeTarget = { id: number; label: string; detail?: string | null }
export type CredentialScopeOptions = {
  scopes: CredentialScopeOption[]
  users: CredentialScopeTarget[]
  repositories: CredentialScopeTarget[]
  teams: CredentialScopeTarget[]
}

export type MysqlConnectionTestResult = {
  success: boolean
  error?: string
}

export function fetchMysqlConnections() {
  return getJson<{ mysql_connections: MysqlConnectionRow[]; credential_scope_options: CredentialScopeOptions }>("/api/v1/app/admin/mysql_connections")
}

export function createMysqlConnection(values: MysqlConnectionInput) {
  return postJson<{ mysql_connection: MysqlConnectionRow }>("/api/v1/app/admin/mysql_connections", { mysql_connection: values })
}

export function updateMysqlConnection(id: number, values: Partial<MysqlConnectionInput>) {
  return patchJson<{ mysql_connection: MysqlConnectionRow }>(`/api/v1/app/admin/mysql_connections/${id}`, { mysql_connection: values })
}

export function deleteMysqlConnection(id: number) {
  return deleteJson<void>(`/api/v1/app/admin/mysql_connections/${id}`)
}

export function testDraftMysqlConnection(values: MysqlConnectionInput) {
  return postJson<MysqlConnectionTestResult>("/api/v1/app/admin/mysql_connections/test", { mysql_connection: values })
}

export function testMysqlConnection(id: number, password?: string) {
  return postJson<MysqlConnectionTestResult>(`/api/v1/app/admin/mysql_connections/${id}/test`, password ? { mysql_connection: { password } } : undefined)
}
