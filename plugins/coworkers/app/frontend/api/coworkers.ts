import { deleteJson, getJson, postForm, postJson } from "@app/api/client"

export type CoworkerSummary = {
  id: number | "syrus"
  name: string
  handle: string
  role_summary: string | null
  state: string
  accent_hex: string
  avatar_key: string | null
  avatar_url: string | null
  path: string
  built_in?: boolean
  chat_model?: string | null
}
export type CoworkerDetail = CoworkerSummary & {
  chat_provider: string | null
  chat_model: string | null
  effective_model: string | null
  workspace_repo: string
  soul: string | null
  chats: { id: number; role: "main" | "side"; title: string; path: string }[]
  grants: { capability: string; approval_policy: string }[]
  available_chats: { id: number; title: string; rostered: boolean; implicit: boolean }[]
}
export type CoworkerModelOptions = {
  provider: string
  provider_label: string
  models: { id: string; label: string }[]
}
export type CoworkerMemoryFile = {
  path: string
  category: "daily" | "people" | "repos" | "banks"
  name: string
  content: string
  truncated: boolean
}
export type CoworkerMemoryPayload = {
  files: CoworkerMemoryFile[]
  search: string
  truncated: boolean
  partial: boolean
  search_incomplete: boolean
}
export type CoworkerWorkspacePayload = {
  remote: string
  branch: string
  files: { path: string; type: string }[]
  partial: boolean
  selected_file: { path: string; content: string; truncated: boolean; binary: boolean } | null
  commits: { sha: string; message: string; authored_at: string | null; source: "chat" | "run" | "unattributed"; source_id: number | null }[]
  conflicts: { branch: string; files: string[]; detail: string | null }[]
}

export const fetchCoworkers = () =>
  getJson<{ coworkers: CoworkerSummary[]; syrus: CoworkerSummary; model_options: CoworkerModelOptions[] }>("/api/v1/app/coworkers")
export const fetchCoworker = (id: string) => getJson<{ coworker: CoworkerDetail }>(`/api/v1/app/coworkers/${id}`)
export const fetchCoworkerMemory = (id: string, search: string) => getJson<CoworkerMemoryPayload>(`/api/v1/app/coworkers/${id}/memory${search}`)
export const fetchCoworkerWorkspace = (id: string, path?: string) =>
  getJson<CoworkerWorkspacePayload>(`/api/v1/app/coworkers/${id}/workspace${path ? `?path=${encodeURIComponent(path)}` : ""}`)
export const createCoworker = (form: FormData) => postForm<{ coworker: CoworkerDetail; redirect_to: string }>("/api/v1/app/coworkers", form)
export const createSideChat = (id: number) => postJson<{ chat_path: string }>(`/api/v1/app/coworkers/${id}/chats`)
export const testCoworkerRemote = (workspaceRepo: string) =>
  postJson<{ message: string }>("/api/v1/app/coworkers/test_remote", { workspace_repo: workspaceRepo })
export const addCoworkerToChat = (coworkerId: number, chatId: number) => postJson(`/api/v1/app/chats/${chatId}/agents/${coworkerId}`)
export const removeCoworkerFromChat = (coworkerId: number, chatId: number) => deleteJson(`/api/v1/app/chats/${chatId}/agents/${coworkerId}`)
