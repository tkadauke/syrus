import { getJson, postJson } from "./client"

export type TerminalSessionPayload = {
  id: number
  name: string
  working_directory: string
  relay_address: string | null
  started_at: string | null
  finished_at: string | null
  outcome: string | null
  workflow_id: number | null
}

export type CreateTerminalSessionInput = {
  workflow_id?: number
  name?: string
  working_directory?: string
}

export function fetchTerminalSessions() {
  return getJson<TerminalSessionPayload[]>("/api/v1/app/terminal_sessions")
}

export function createTerminalSession(input: CreateTerminalSessionInput = {}) {
  return postJson<TerminalSessionPayload>("/api/v1/app/terminal_sessions", input)
}

export function fetchTerminalSession(id: number | string) {
  return getJson<TerminalSessionPayload>(`/api/v1/app/terminal_sessions/${id}`)
}

export function killTerminalSession(id: number | string) {
  return postJson<TerminalSessionPayload>(`/api/v1/app/terminal_sessions/${id}/kill`)
}
