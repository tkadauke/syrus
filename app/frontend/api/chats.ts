import { ApiError, deleteJson, getJson, patchJson, postJson } from "./client"

export type ChatRepository = {
  id: number
  slug: string
  repository_path?: string
}

export type ChatMode = "planning" | "coding" | "local"

export type ChatRecord = {
  id: number
  title: string | null
  title_pending: boolean
  pinned: boolean
  pinned_context: string | null
  chat_provider?: string | null
  effective_chat_provider?: string
  effective_chat_provider_label?: string
  chat_provider_options?: ChatProviderOption[]
  mode?: ChatMode | null
  local_daemon_state?: "connected" | "disconnected" | null
  local_daemon_repo?: string | null
  local_daemon_branch?: string | null
  chat_path: string
  repository: ChatRepository | null
  turn_in_flight?: boolean
  agent_busy?: boolean
  stop_requested_at: string | null
  suggested_next_step?: string | null
  cumulative_input_tokens: number
  cumulative_output_tokens: number
  cumulative_cost_usd: number
  pending_proposal_count?: number
  confirmed_proposal_count?: number
  scratchpad_items_count?: number
  coding_checkout_uncommitted?: boolean
  coding_checkout_branch?: string | null
}

export type ChatProviderOption = {
  value: string | null
  label: string
  configured: boolean
  effective_provider: string
  effective_label: string
}

export type ChatNavRecord = ChatRecord & {
  current?: boolean
  last_message_at: string | null
  unread: boolean
  pending_proposal_count: number
  scratchpad_items_count: number
  created_at?: string
  updated_at?: string
}

export type HiddenChatRecord = ChatNavRecord & {
  hidden_at: string | null
  app_unhide_path: string
}

export type ChatSystemMessage = {
  tone: "success" | "warning" | "error" | "neutral"
  label: string
  body: string
  cta?: {
    label: string
    path: string
  }
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
  dependency_slugs?: string[]
  dependencies: ChatProposalDependency[]
  has_dependencies: boolean
  target_epic_label: string | null
  app_update_path: string
  app_confirm_path: string
  app_reject_path: string
  depends_on_job_ids?: number[]
  depends_on_epic_ids?: number[]
  materialized_label: string | null
  materialized_path: string | null
  materialized?: ChatProposalMaterialized | null
  materialized_epic_state?: string | null
  materialized_epic_state_path?: string | null
  active_children_count?: number
  children?: ChatProposalChild[]
}

export type ChatProposalDependency = {
  slug: string
  title: string
  display_label?: string
  state: string
  confirmed: boolean
  anchor_message_id?: number | null
  materialized_label?: string | null
  materialized_path?: string | null
}

export type ChatProposalMaterialized =
  | { kind: "job"; job_id: number; job_title: string | null; job_state: string | null }
  | { kind: "epic"; epic_id: number; epic_title: string | null; child_jobs: Array<{ job_id: number | null; title: string | null }> }
  | { kind: "rejected"; reason: string }

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
  depends_on_job_ids?: number[]
  depends_on_epic_ids?: number[]
  dependency_details?: ChatProposalChildDependency[]
  app_update_path: string
  app_reject_path: string
}

export type ChatProposalUpdateInput = {
  title: string
  body: string
  dependency_slugs: string[]
  depends_on_job_ids: number[]
  depends_on_epic_ids: number[]
}

export type ChatProposalSearchResult = {
  id: number
  slug: string
  title: string
  state?: string
}

export type ChatJobDependencySearchResult = {
  id: number
  title?: string | null
  issue_title?: string | null
}

export type ChatEpicDependencySearchResult = {
  id: number
  number?: number
  title: string
  display_number?: string
}

export type ChatProposalChildDependency = {
  slug: string
  title: string
  scope: "sibling" | "cross_card"
  confirmed: boolean
  materialized_label?: string | null
  materialized_path?: string | null
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
  created_at?: string
  attachments?: Array<{ name: string; mime_type: string; data: string }>
  video_walkthrough_id?: number
  proposal?: ChatProposal | null
  pending_action?: ChatPendingActionInline | null
}

export type ChatPendingActionInline = {
  id: number
  action: string | null
  state: string
  label: string
  detail: string | null
  resource_title?: string
  resource_url?: string
  app_confirm_path: string
  app_reject_path: string
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
  detail: string | null
  state: "queued" | "pending" | "confirmed" | "rejected" | "cancelled"
  action: string | null
  action_type: string | null
  chat_message_id?: number | null
  app_confirm_path: string
  app_reject_path: string
  app_cancel_path: string
}

export type ChatAgentQuestion = {
  id: number
  question: string
  options: string[] | null
  asked_at: string | null
  app_answer_path: string
}

export type ChatQueuedMessage = {
  id: number
  text: string
  created_at: string | null
  app_update_path: string
  app_delete_path: string
}

export type ChatScratchpadItem = {
  id: number
  content: string
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

export type WhiteboardSnapshot = {
  id: number
  name: string | null
  snapshot_kind: "manual" | "auto_clear" | "auto_before_load"
  element_count: number
  created_at: string
  scene_json?: ChatWhiteboardScene
}

export type WhiteboardSnapshotsPayload = {
  whiteboard_snapshots: WhiteboardSnapshot[]
}

export type CreateChatInput = {
  repositoryId: string
  text: string
  attachments?: ChatMessageAttachmentInput[]
}

export type NewChatPayload = {
  default_repository_id: number | null
}

export type ChatMessageAttachmentInput = {
  name: string
  mimeType: string
  dataUrl: string
}

export type ChatCreatedPayload = {
  message: string
  redirect_to: string
  chat: ChatRecord
}

export type ChatBranchPayload = {
  id: number
  app_path: string
}

export type ChatGroupRecord = {
  key: string
  label: string
  repository_id: number | null
  chats: ChatNavRecord[]
  has_more: boolean
}

export type ChatsIndexPayload = {
  groups: ChatGroupRecord[]
  repositories: ChatRepository[]
}

export type MoreChatsPayload = {
  chats: ChatNavRecord[]
  has_more: boolean
}

export type HiddenChatsPayload = {
  chats: HiddenChatRecord[]
  total: number
  page: number
  per_page: number
  total_pages: number
}

export type ChatWalkthroughMedia = {
  id: number
  title: string
  state: string
  duration_seconds: number | null
  byte_size: number | null
  error_message: string | null
  has_video: boolean
  created_at: string
}

export type CodingFilesPayload = {
  files: string[]
  checkout_branch: string | null
}

export type CodingFileContentPayload = {
  path: string
  content: string | null
  binary: boolean
  too_large: boolean
  size?: number
}

export type CodingDiffPayload = {
  diff: string
  mode: "cumulative" | "turn"
  checkout_branch: string | null
}

export type ChatPayload = {
  message?: string | null
  chat: ChatRecord
  chat_available: boolean
  turn_in_flight: boolean
  agent_busy: boolean
  switching_provider: boolean
  has_more_older: boolean
  messages: ChatMessageItem[]
  bookmarks: ChatBookmark[]
  recent_chats: ChatNavRecord[]
  pending_actions: ChatPendingAction[]
  agent_questions: ChatAgentQuestion[]
  queued_messages: ChatQueuedMessage[]
  scratchpad_items: ChatScratchpadItem[]
  video_walkthroughs: ChatWalkthroughMedia[]
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
    credentials_path: string
    repositories_path: string
    app_messages_path: string
    app_message_path: string
    app_rename_path: string
    app_delete_path?: string
    app_clear_path: string
    app_branch_path: string
    app_share_path: string
    app_enqueue_message_path: string
    app_stop_path: string
    app_daemon_connection_path: string
    app_bookmarks_path: string
    app_attachments_path: string
    app_video_walkthroughs_path: string
    app_whiteboard_path: string
    app_switch_provider_path: string
    app_scratchpad_reorder_path: string
    app_cancel_coding_checkout_path?: string
    app_coding_files_path?: string
    app_coding_file_path?: string
    app_coding_diff_path?: string
  }
  gemini_configured: boolean
  walkthroughs_enabled: boolean
  coding_mode_enabled: boolean
  local_mode_enabled: boolean
  local_tunnel_connected: boolean
}

export type ChatMessagesPayload = {
  has_more_older: boolean
  messages: ChatMessageItem[]
}

export type SharedChatPayload = {
  chat: {
    id: number
    title: string | null
  }
  messages: ChatMessageItem[]
}

export type ShareChatPayload = {
  share_url: string
}

export type ChatSearchMatch = {
  message_id: number
  role: "user" | "assistant" | "tool_use" | "tool_result" | "system" | string
  snippet: string | null
  created_at: string | null
}

export type ChatSearchResult = {
  chat_session_id: number
  chat_title: string
  best_snippet: string | null
  best_match_message_id: number | null
  top_matches: ChatSearchMatch[]
  total_match_count: number
  has_more_matches: boolean
}

export type ChatSearchPayload = {
  results: ChatSearchResult[]
  total: number
  page: number
  per_page: number
}

export type ChatSearchMessagesPayload = {
  matches: ChatSearchMatch[]
}

export function fetchChat(id: string, search = "") {
  return getJson<ChatPayload>(`/api/v1/app/chats/${id}${search}`)
}

export function fetchSharedChat(token: string) {
  return getJson<SharedChatPayload>(`/api/v1/app/shared_chats/${encodeURIComponent(token)}`)
}

export function markChatRead(id: string | number) {
  return patchJson<void>(`/api/v1/app/chats/${id}/mark_read`)
}

export function markChatUnread(id: string | number) {
  return patchJson<void>(`/api/v1/app/chats/${id}/mark_unread`)
}

export function hideChat(id: string | number) {
  return patchJson<{ message: string; chat: ChatNavRecord }>(`/api/v1/app/chats/${id}/hide`)
}

export function unhideChat(path: string) {
  return patchJson<{ message: string; chat: ChatNavRecord }>(path)
}

export function fetchChats() {
  return getJson<ChatsIndexPayload>("/api/v1/app/chats")
}

export function fetchNewChat() {
  return getJson<NewChatPayload>("/api/v1/app/chats/new")
}

export function fetchHiddenChats(page = 1) {
  return getJson<HiddenChatsPayload>(`/api/v1/app/settings/hidden_chats?page=${encodeURIComponent(String(page))}`)
}

export function fetchMoreChatsForGroup(repositoryId: number | null, beforeChatId: number) {
  const repositoryParam = repositoryId == null ? "general" : String(repositoryId)
  return getJson<MoreChatsPayload>(`/api/v1/app/chats/more?repository_id=${encodeURIComponent(repositoryParam)}&before_id=${encodeURIComponent(String(beforeChatId))}`)
}

export function fetchChatSearch(search = "", options: { signal?: AbortSignal } = {}) {
  return getJson<ChatSearchPayload>(`/api/v1/app/chats/search${search}`, options)
}

export function fetchChatSearchMessages(search = "", options: { signal?: AbortSignal } = {}) {
  return getJson<ChatSearchMessagesPayload>(`/api/v1/app/chats/search/messages${search}`, options)
}

export function fetchChatMessages(path: string, before: number) {
  return getJson<ChatMessagesPayload>(`${path}?before=${encodeURIComponent(String(before))}`)
}

export function fetchChatWhiteboard(path: string) {
  return getJson<ChatWhiteboardPayload>(path)
}

export function fetchWhiteboardSnapshots(chatSessionId: string | number) {
  return getJson<WhiteboardSnapshotsPayload>(`/api/v1/app/chats/${encodeURIComponent(String(chatSessionId))}/whiteboard_snapshots`)
}

export function fetchWhiteboardSnapshot(chatSessionId: string | number, snapshotId: string | number) {
  return getJson<WhiteboardSnapshot>(`/api/v1/app/chats/${encodeURIComponent(String(chatSessionId))}/whiteboard_snapshots/${encodeURIComponent(String(snapshotId))}`)
}

export function createWhiteboardSnapshot(chatSessionId: string | number, input: { scene_json: ChatWhiteboardScene; snapshot_kind: WhiteboardSnapshot["snapshot_kind"]; name?: string | null }) {
  return postJson<WhiteboardSnapshot>(`/api/v1/app/chats/${encodeURIComponent(String(chatSessionId))}/whiteboard_snapshots`, input)
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

export function createChat(values: CreateChatInput) {
  return postJson<ChatCreatedPayload>("/api/v1/app/chats", {
    repository_id: values.repositoryId,
    ...chatMessagePayload(values.text, values.attachments || [])
  })
}

export function createEmptyChat(repositoryId?: number | string | null) {
  const payload = repositoryId == null || repositoryId === "" ? undefined : { repository_id: repositoryId }
  return postJson<ChatCreatedPayload>("/api/v1/app/chats", payload)
}

// Create the first-run onboarding chat (seeded so the agent greets the
// operator and walks them through their first Epic).
export function startOnboardingChat() {
  return postJson<ChatCreatedPayload>("/api/v1/app/chats/onboarding")
}

export function sendChatMessage(path: string, text: string, attachments: ChatMessageAttachmentInput[] = []) {
  return postJson<ChatPayload>(path, chatMessagePayload(text, attachments))
}

export function renameChat(path: string, title: string) {
  return patchJson<ChatPayload>(path, { chat: { title } })
}

export function updateChatPinned(id: number | string, pinned: boolean) {
  return patchJson<ChatPayload>(`/api/v1/app/chats/${id}`, { chat: { pinned } })
}

export function updateChatProvider(id: number | string, chatProvider: string | null) {
  return patchJson<ChatPayload>(`/api/v1/app/chats/${id}`, { chat: { chat_provider: chatProvider } })
}

export function updateChatMode(id: number | string, mode: ChatMode | null) {
  return patchJson<ChatPayload>(`/api/v1/app/chats/${id}`, { chat: { mode: mode ?? "" } })
}

export function cancelCodingCheckout(path: string) {
  return deleteJson<ChatPayload>(path)
}


export function clearChatHistory(path: string) {
  return deleteJson<ChatPayload>(path)
}

// Hard-deletes the chat and all of its data (messages, attachments,
// workspace). The server refuses with a 409 while a turn is running.
export function deleteChat(id: number | string) {
  return deleteJson<{ message: string }>(`/api/v1/app/chats/${id}`)
}

export function branchChat(path: string) {
  return postJson<ChatBranchPayload>(path)
}

export function shareChat(path: string) {
  return postJson<ShareChatPayload>(path)
}

export function enqueueChatMessage(path: string, text: string, attachments: ChatMessageAttachmentInput[] = []) {
  return postJson<ChatPayload>(path, chatMessagePayload(text, attachments))
}

export function updateQueuedChatMessage(path: string, text: string) {
  return patchJson<ChatPayload>(path, { chat_message: { text } })
}

export function deleteQueuedChatMessage(path: string) {
  return deleteJson<ChatPayload>(path)
}

export function createScratchpadItem(chatId: string | number, content: string) {
  return postJson<ChatPayload>(`/api/v1/app/chats/${chatId}/scratchpad_items`, { scratchpad_item: { content } })
}

export function updateScratchpadItem(path: string, content: string) {
  return patchJson<ChatPayload>(path, { scratchpad_item: { content } })
}

export function deleteScratchpadItem(path: string) {
  return deleteJson<ChatPayload>(path)
}

export function reorderScratchpadItems(chatId: string | number, ids: number[]) {
  return patchJson<ChatPayload>(`/api/v1/app/chats/${chatId}/scratchpad_items/reorder`, { ids })
}

export function stopChat(path: string) {
  return postJson<ChatPayload>(path)
}

export function switchChatProvider(path: string, provider: string) {
  return postJson<{ message: string }>(path, { provider })
}

function chatMessagePayload(text: string, attachments: ChatMessageAttachmentInput[]) {
  const chatMessage: {
    text: string
    attachments?: Array<{ name: string; mime_type: string; data: string }>
  } = { text }

  if (attachments.length > 0) {
    chatMessage.attachments = attachments.map((attachment) => ({
      name: attachment.name,
      mime_type: attachment.mimeType,
      data: attachment.dataUrl.replace(/^data:[^;]+;base64,/, "")
    }))
  }

  return { chat_message: chatMessage }
}

export function createChatBookmark(path: string, messageId: number, label: string) {
  return postJson<ChatPayload>(path, {
    message_id: messageId,
    chat_bookmark: { label }
  })
}

export function createChatTopicBookmark(path: string, label: string) {
  return postJson<ChatPayload>(path, {
    chat_bookmark: { label, kind: "topic" }
  })
}

export function addChatAttachment(path: string, record: ChatAttachmentResult) {
  return postJson<ChatPayload>(path, {
    attachable_type: record.type,
    attachable_id: record.id
  })
}

export function attachChatRepository(path: string, slug: string) {
  return postJson<ChatPayload>(path, {
    attachable_type: "Repository",
    repository_slug: slug
  })
}

export function deleteChatAttachment(path: string) {
  return deleteJson<ChatPayload>(path)
}

// `start: true` asks the server to also move a materialized Epic to
// In progress and dispatch its ready child Jobs right after confirming.
export function confirmChatProposal(path: string, options: { start?: boolean } = {}) {
  return postJson<ChatPayload>(path, options.start ? { start: true } : undefined)
}

export function rejectChatProposal(path: string) {
  return postJson<ChatPayload>(path)
}

export function updateChatProposal(path: string, values: ChatProposalUpdateInput) {
  return patchJson<ChatPayload>(path, { proposal: values })
}

export function searchChatProposals(chatId: string | number, query: string, excludeId: number, options: { signal?: AbortSignal } = {}) {
  const params = new URLSearchParams({ q: query, exclude_id: String(excludeId) })
  return getJson<{ proposals: ChatProposalSearchResult[] }>(`/api/v1/app/chats/${chatId}/proposals/search?${params}`, options)
    .then((payload) => payload.proposals || [])
}

export function searchChatJobs(query: string, options: { signal?: AbortSignal } = {}) {
  const params = new URLSearchParams({ q: query, limit: "10" })
  return getJson<{ jobs: ChatJobDependencySearchResult[] }>(`/api/v1/app/jobs?${params}`, options)
    .then((payload) => payload.jobs || [])
}

export function searchChatEpics(query: string, options: { signal?: AbortSignal } = {}) {
  const params = new URLSearchParams({ q: query, limit: "10" })
  return getJson<{ epics: ChatEpicDependencySearchResult[] }>(`/api/v1/app/epics?${params}`, options)
    .then((payload) => payload.epics || [])
}

export function confirmPendingAction(path: string) {
  return postJson<ChatPayload>(path)
}

export function rejectPendingAction(path: string) {
  return postJson<ChatPayload>(path)
}

export function cancelPendingAction(path: string) {
  return deleteJson<ChatPayload>(path)
}

export function answerAgentQuestion(path: string, answer: string) {
  return postJson<ChatPayload>(path, { answer })
}

export function fetchCodingFileTree(path: string) {
  return getJson<CodingFilesPayload>(path)
}

export function fetchCodingFileContent(basePath: string, filePath: string) {
  const params = new URLSearchParams({ path: filePath })
  return getJson<CodingFileContentPayload>(`${basePath}?${params}`)
}

export function fetchCodingDiff(path: string, mode: "cumulative" | "turn" = "cumulative") {
  return getJson<CodingDiffPayload>(`${path}?mode=${mode}`)
}

export type ChatJobStatusBlocker = {
  reason: "awaiting_review" | "landing_failed" | "dependency_failed"
  description: string
}

export type ChatJobStatusJobItem = {
  kind: "job"
  job_id: number
  slug: string
  title: string | null
  state: string
  workflow_step: string | null
  pr_number: number | null
  pr_url: string | null
  blocker: ChatJobStatusBlocker | null
}

export type ChatJobStatusEpicItem = {
  kind: "epic"
  epic_id: number
  slug: string
  title: string | null
  state: string
  progress: { done: number; total: number }
  children: ChatJobStatusJobItem[]
}

export type ChatJobStatusItem = ChatJobStatusEpicItem | ChatJobStatusJobItem

export function fetchChatJobStatus(chatId: string | number) {
  return getJson<ChatJobStatusItem[]>(`/api/v1/app/chats/${encodeURIComponent(String(chatId))}/job_status`)
}
