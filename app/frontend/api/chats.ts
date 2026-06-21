import { ApiError, deleteJson, getJson, patchJson, postJson } from "./client"

export type ChatRepository = {
  id: number
  slug: string
  repository_path?: string
}

export type ChatRecord = {
  id: number
  title: string | null
  title_pending: boolean
  chat_path: string
  repository: ChatRepository | null
  stop_requested_at: string | null
  cumulative_input_tokens: number
  cumulative_output_tokens: number
  cumulative_cost_usd: number
}

export type ChatNavRecord = ChatRecord & {
  current: boolean
  last_message_at: string | null
  unread: boolean
}

export type ChatSystemMessage = {
  tone: "success" | "warning" | "error" | "neutral"
  label: string
  body: string
}

export type ChatMcpHealth = {
  name: string
  status: string
  available_tools: string[]
  pending_tools: string[]
  unavailable_tools: string[]
}

export type ChatProposal = {
  id: number
  kind: string
  kind_label: string
  state: string
  state_label: string
  title: string
  slug: string
  body: string
  proposed: boolean
  resolved: boolean
  epic_bundle: boolean
  scoped_repository_slug: string | null
  dependencies: string[]
  target_epic_label: string | null
  app_confirm_path: string
  app_reject_path: string
  materialized_label: string | null
  materialized_path: string | null
  materialized_epic_state?: string | null
  materialized_epic_state_path?: string | null
  active_children_count?: number
  children?: ChatProposalChild[]
}

export type ChatProposalChild = {
  id: number
  title: string
  slug: string
  body: string
  state: string
  state_label: string
  proposed: boolean
  repository_slug: string | null
  dependencies: string[]
  app_reject_path: string
}

export type ChatStructuredTool = {
  name: string
  payload: unknown
  proposal_id: number | null
  proposal_state_label: string | null
}

export type ChatMessageItem = {
  type: "message"
  id: number
  role: "user" | "assistant" | "tool_use" | "tool_result" | "system"
  tool_name?: string | null
  content?: unknown
  text: string
  bookmarkable: boolean
  proposal?: ChatProposal | null
}

export type ChatRenderMessageItem = ChatMessageItem & {
  tool?: ChatStructuredTool
  system?: ChatSystemMessage
}

export type ChatToolGroupItem = {
  type: "tool_group"
  tool: string
  calls: Array<{
    message_id: number
    detail: string
    result_body: string
    result_error: boolean
    result_summary: string
  }>
}

export type ChatRenderItem = ChatRenderMessageItem | ChatToolGroupItem

export type ChatBookmark = {
  id: number
  label: string
  chat_message_id: number
  anchor_message_id?: number
}

export type ChatPendingAction = {
  id: number
  label: string
  action: string | null
  action_type: string | null
  app_confirm_path: string
  app_cancel_path: string
}

export type ChatQueuedMessage = {
  id: number
  text: string
  created_at: string | null
  app_update_path: string
  app_delete_path: string
}

export type ChatAttachmentRow = {
  id: number
  label: string
  app_detach_path: string
}

export type ChatDocumentScope = {
  id: number
  title: string
  repository_slug: string | null
}

export type ChatAttachmentResult = {
  type: string
  id: number
  label: string
}

export type ChatWhiteboardElement = Record<string, unknown>
export type ChatWhiteboardAppState = Record<string, unknown>
export type ChatWhiteboardFiles = Record<string, Record<string, unknown>>

export type ChatWhiteboardPayload = {
  scene_json: ChatWhiteboardScene
  version: number
}

export type ChatWhiteboardScene = {
  elements: ChatWhiteboardElement[]
  appState: ChatWhiteboardAppState
  files: ChatWhiteboardFiles
}

export type NewChatPayload = {
  repositories: ChatRepository[]
  repositories_path: string
}

export type CreateChatInput = {
  repositoryId: string
  text: string
}

export type ChatCreatedPayload = {
  message: string
  redirect_to: string
  chat: ChatRecord
}

export type ChatPayload = {
  message?: string | null
  chat: ChatRecord
  chat_available: boolean
  turn_in_flight: boolean
  agent_busy: boolean
  has_more_older: boolean
  messages: ChatMessageItem[]
  bookmarks: ChatBookmark[]
  recent_chats: ChatNavRecord[]
  pending_actions: ChatPendingAction[]
  queued_messages: ChatQueuedMessage[]
  attachment_groups: {
    repositories: ChatAttachmentRow[]
    epics: ChatAttachmentRow[]
    jobs: ChatAttachmentRow[]
    documents: ChatAttachmentRow[]
  }
  documents_in_scope: ChatDocumentScope[]
  attachment_results: ChatAttachmentResult[]
  whiteboard: {
    version: number
    elements: ChatWhiteboardElement[]
    appState: ChatWhiteboardAppState
    files: ChatWhiteboardFiles
  }
  paths: {
    new_chat_path: string
    credentials_path: string
    repositories_path: string
    app_messages_path: string
    app_message_path: string
    app_enqueue_message_path: string
    app_stop_path: string
    app_bookmarks_path: string
    app_attachments_path: string
    app_whiteboard_path: string
  }
}

export type ChatMessagesPayload = {
  has_more_older: boolean
  messages: ChatMessageItem[]
}

export function fetchChat(id: string, search = "") {
  return getJson<ChatPayload>(`/api/v1/app/chats/${id}${search}`)
}

export function markChatRead(id: string | number) {
  return patchJson<void>(`/api/v1/app/chats/${id}/mark_read`)
}

export function fetchChatMessages(path: string, before: number) {
  return getJson<ChatMessagesPayload>(`${path}?before=${encodeURIComponent(String(before))}`)
}

export function fetchChatWhiteboard(path: string) {
  return getJson<ChatWhiteboardPayload>(path)
}

export async function patchChatWhiteboard(path: string, input: ChatWhiteboardScene & { expected_version: number }) {
  try {
    return { status: 200, payload: await patchJson<ChatWhiteboardPayload>(path, input) }
  } catch (error) {
    if (error instanceof ApiError && error.status === 409) {
      return { status: 409, payload: await fetchChatWhiteboard(path) }
    }

    throw error
  }
}

export function fetchNewChat() {
  return getJson<NewChatPayload>("/api/v1/app/chats/new")
}

export function createChat(values: CreateChatInput) {
  return postJson<ChatCreatedPayload>("/api/v1/app/chats", {
    repository_id: values.repositoryId,
    chat_message: { text: values.text }
  })
}

// Create the first-run onboarding chat (seeded so the agent greets the
// operator and walks them through their first Epic).
export function startOnboardingChat() {
  return postJson<ChatCreatedPayload>("/api/v1/app/chats/onboarding")
}

export function sendChatMessage(path: string, text: string) {
  return postJson<ChatPayload>(path, { chat_message: { text } })
}

export function enqueueChatMessage(path: string, text: string) {
  return postJson<ChatPayload>(path, { chat_message: { text } })
}

export function updateQueuedChatMessage(path: string, text: string) {
  return patchJson<ChatPayload>(path, { chat_message: { text } })
}

export function deleteQueuedChatMessage(path: string) {
  return deleteJson<ChatPayload>(path)
}

export function stopChat(path: string) {
  return postJson<ChatPayload>(path)
}

export function createChatBookmark(path: string, messageId: number, label: string) {
  return postJson<ChatPayload>(path, {
    message_id: messageId,
    chat_bookmark: { label }
  })
}

export function addChatAttachment(path: string, record: ChatAttachmentResult) {
  return postJson<ChatPayload>(path, {
    attachable_type: record.type,
    attachable_id: record.id
  })
}

export function deleteChatAttachment(path: string) {
  return deleteJson<ChatPayload>(path)
}

export function confirmChatProposal(path: string) {
  return postJson<ChatPayload>(path)
}

export function rejectChatProposal(path: string) {
  return postJson<ChatPayload>(path)
}

export function confirmPendingAction(path: string) {
  return postJson<ChatPayload>(path)
}

export function cancelPendingAction(path: string) {
  return deleteJson<ChatPayload>(path)
}
