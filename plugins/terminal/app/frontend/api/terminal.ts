import { deleteJson, getJson, postJson } from "@app/api/client"

export type TerminalSessionRecord = {
  id: number
  name: string
  working_directory: string
  started_at: string
  finished_at: string | null
  outcome: string | null
  workflow_id: number | null
  chat_session_id: number | null
  worker_hostname: string | null
  worker_storage_key: string | null
  queue_name: string | null
  workspace_kind: string | null
}

export type TerminalWorkspaceRecord = {
  key: string
  id: number | string | null
  label: string
  secondary_text?: string
  working_directory: string
  kind: "scratch" | "workflow" | "chat" | "worker"
  section: "interesting_workflows" | "coding_chats" | "workers"
  section_title: string
  state?: string
  actionability?: string
  workflow_id?: number
  chat_session_id?: number
  worker_hostname?: string
  worker_storage_key?: string
  queue_name?: string
  default_visible?: boolean
  search_text?: string
  available?: boolean
  disabled_reason?: string | null
}

export type TerminalSessionsPayload = {
  sessions: TerminalSessionRecord[]
  workspaces: TerminalWorkspaceRecord[]
}

export type TerminalSessionPayload = {
  session: TerminalSessionRecord
}

export type CreateTerminalSessionInput =
  | TerminalWorkspaceRecord
  | {
      workflow_id?: number
      working_directory?: string
      name?: string
    }

export function fetchTerminalSessions(options: { signal?: AbortSignal } = {}) {
  return getJson<TerminalSessionsPayload>("/api/v1/app/terminal_sessions", options)
}

export function createTerminalSession(input: CreateTerminalSessionInput) {
  return postJson<TerminalSessionPayload>("/api/v1/app/terminal_sessions", {
    terminal_session: {
      candidate_key: "kind" in input ? input.key : undefined,
      workflow_id: "kind" in input ? (input.kind === "workflow" ? (input.workflow_id ?? input.id) : null) : input.workflow_id,
      working_directory: input.working_directory,
      name: "kind" in input ? input.label : input.name
    }
  })
}

export function killTerminalSession(id: number) {
  return deleteJson<TerminalSessionPayload>(`/api/v1/app/terminal_sessions/${id}`)
}
