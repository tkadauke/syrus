import { getJson, postForm, postJson } from "@app/api/client"

export type CoworkerSummary = {
  id: number | "syrus"
  name: string
  handle: string
  role_summary: string | null
  state: string
  color_key: string
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
}
export type CoworkerModelOptions = {
  provider: string
  provider_label: string
  models: { id: string; label: string }[]
}

export const fetchCoworkers = () =>
  getJson<{ coworkers: CoworkerSummary[]; syrus: CoworkerSummary; model_options: CoworkerModelOptions[] }>("/api/v1/app/coworkers")
export const fetchCoworker = (id: string) => getJson<{ coworker: CoworkerDetail }>(`/api/v1/app/coworkers/${id}`)
export const createCoworker = (form: FormData) => postForm<{ coworker: CoworkerDetail; redirect_to: string }>("/api/v1/app/coworkers", form)
export const createSideChat = (id: number) => postJson<{ chat_path: string }>(`/api/v1/app/coworkers/${id}/chats`)
export const testCoworkerRemote = (workspaceRepo: string) =>
  postJson<{ message: string }>("/api/v1/app/coworkers/test_remote", { workspace_repo: workspaceRepo })
