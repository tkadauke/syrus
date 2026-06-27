import { deleteJson, getJson, postJson } from "./client"

export type TerminalSessionRecord = {
  id: number
  name: string
  working_directory: string
  started_at: string
  finished_at: string | null
  outcome: string | null
  workflow_id: number | null
}

export type TerminalWorkspaceRecord = {
  id: number | null
  label: string
  working_directory: string
  kind: "scratch" | "workflow"
}

export type TerminalSessionsPayload = {
  sessions: TerminalSessionRecord[]
  workspaces: TerminalWorkspaceRecord[]
}

export type TerminalSessionPayload = {
  session: TerminalSessionRecord
}

export function fetchTerminalSessions(options: { signal?: AbortSignal } = {}) {
  return getJson<TerminalSessionsPayload>("/api/v1/app/terminal_sessions", options)
}

export function createTerminalSession(workspace: TerminalWorkspaceRecord) {
  return postJson<TerminalSessionPayload>("/api/v1/app/terminal_sessions", {
    terminal_session: {
      workflow_id: workspace.kind === "workflow" ? workspace.id : null,
      working_directory: workspace.working_directory,
      name: workspace.label
    }
  })
}

export function killTerminalSession(id: number) {
  return deleteJson<TerminalSessionPayload>(`/api/v1/app/terminal_sessions/${id}`)
}
