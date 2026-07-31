import type { QueryClient, QueryKey } from "@tanstack/react-query"
import type { ChatAgentQuestion, ChatBookmark, ChatMessageItem, ChatPayload, ChatQueuedMessage, ChatRecord, ChatRepository } from "../api/chats"
import { updateRecentChatHeaderCache, updateRecentChatScratchpadCache, updateRecentChatTurnCache } from "./chatRecentCache"

const DASHBOARD_INVALIDATION_MIN_INTERVAL_MS = 5_000
const DASHBOARD_INVALIDATION_RETRY_MS = 1_000

type DashboardInvalidationState = {
  lastInvalidatedAt: number
  pending: boolean
  timer: ReturnType<typeof setTimeout> | null
}

const dashboardInvalidations = new WeakMap<QueryClient, DashboardInvalidationState>()

export type AppEvent = {
  type: string
  resource?: string
  id?: number | string | null
  changed?: string[]
  occurred_at?: string
  payload?: unknown
  unread_count?: number
}

type NotificationsCache = {
  notifications: Array<{ id: number; read_at: string | null }>
  unread_count: number
  pagination: {
    page: number
    per_page: number
    total: number
    total_pages: number
  }
}

type NotificationReadPayload = {
  notification_ids?: number[]
  all_read?: boolean
  read_at?: string
}

export function applyAppEvent(queryClient: QueryClient, event: AppEvent) {
  if (event.type.startsWith("video_walkthrough.")) {
    // The chat composer owns the walkthrough chip; hand it the payload
    // directly (a chat-scoped query invalidation would not carry state).
    if (typeof window !== "undefined") {
      window.dispatchEvent(new CustomEvent("syrus:video-walkthrough", {
        detail: { id: event.id, ...(event.payload as object | undefined) }
      }))
    }
    return
  }

  if (event.type === "notification_created") {
    const current = queryClient.getQueryData<{ unread_count: number }>(["notifications"])
    const unreadCount = typeof event.unread_count === "number" ? event.unread_count : (current?.unread_count ?? 0) + 1
    queryClient.setQueryData(["notifications"], current ? {
      ...current,
      unread_count: unreadCount
    } : {
      notifications: [],
      unread_count: unreadCount,
      pagination: {
        page: 1,
        per_page: 20,
        total: 0,
        total_pages: 0
      }
    })
    void queryClient.invalidateQueries({ queryKey: ["notifications"] })
    return
  }

  if (event.type === "notification_read") {
    const payload = notificationReadPayload(event.payload)
    const readAt = payload?.read_at ?? event.occurred_at ?? new Date().toISOString()
    queryClient.setQueryData<NotificationsCache>(["notifications"], (current) => {
      const unreadCount = typeof event.unread_count === "number" ? event.unread_count : current?.unread_count ?? 0
      if (!current) return emptyNotificationsCache(unreadCount)

      const readIds = new Set(payload?.notification_ids ?? [])
      return {
        ...current,
        unread_count: unreadCount,
        notifications: current.notifications.map((notification) => {
          if (!payload?.all_read && !readIds.has(notification.id)) return notification

          return {
            ...notification,
            read_at: notification.read_at ?? readAt
          }
        })
      }
    })
    void queryClient.invalidateQueries({ queryKey: ["notifications"] })
    return
  }

  if (applyChatPayloadEvent(queryClient, event)) return

  let dashboardChanged = false
  for (const queryKey of queryKeysFor(event)) {
    if (isDashboardQueryKey(queryKey)) {
      dashboardChanged = true
      continue
    }

    void queryClient.invalidateQueries({ queryKey })
  }
  if (dashboardChanged) scheduleDashboardInvalidation(queryClient)
}

function emptyNotificationsCache(unreadCount: number): NotificationsCache {
  return {
    notifications: [],
    unread_count: unreadCount,
    pagination: {
      page: 1,
      per_page: 20,
      total: 0,
      total_pages: 0
    }
  }
}

function notificationReadPayload(payload: unknown): NotificationReadPayload | null {
  if (!payload || typeof payload !== "object") return null

  const candidate = payload as NotificationReadPayload
  return {
    notification_ids: Array.isArray(candidate.notification_ids) ? candidate.notification_ids.filter((id) => typeof id === "number") : [],
    all_read: candidate.all_read === true,
    read_at: typeof candidate.read_at === "string" ? candidate.read_at : undefined
  }
}

export function queryKeysFor(event: AppEvent): QueryKey[] {
  switch (event.resource) {
    case "user":
      return [["bootstrap"]]
    case "job":
      return jobQueryKeysFor(event)
    case "workflow":
      return event.id == null ? [["dashboard"], ["workflows"]] : [["dashboard"], ["workflows"], ["workflows", String(event.id)]]
    case "epic":
      return event.id == null ? [["dashboard"], ["epics"]] : [["dashboard"], ["epics"], ["epics", String(event.id)]]
    case "repository":
      return event.id == null ? [["dashboard"], ["repositories"]] : [["dashboard"], ["repositories"], ["repositories", String(event.id)]]
    case "chat":
      return event.id == null
        ? [["chats"]]
        : event.changed?.includes("whiteboard_snapshots")
          ? [["chats"], ["chats", String(event.id)], ["whiteboard_snapshots", String(event.id)]]
          : [["chats"], ["chats", String(event.id)]]
    case "provider_availability":
      return [["dashboard"], ["jobs"], ["chats"]]
    case "admin_overview":
      return [["admin", "overview"], ["admin", "stuck"]]
    default:
      return []
  }
}

function jobQueryKeysFor(event: AppEvent): QueryKey[] {
  if (event.id == null) return [["dashboard"], ["jobs"], ["job_run_artifacts"]]

  const id = String(event.id)
  const detailKey: QueryKey = workflowOnlyJobEvent(event) ? ["jobs", id, "workflows"] : ["jobs", id, "detail"]
  return [["dashboard"], ["jobs"], detailKey, ["job_run_artifacts", id]]
}

function workflowOnlyJobEvent(event: AppEvent) {
  const changed = event.changed || []
  return changed.some((item) => item.startsWith("run.") || item.startsWith("step.") || item.startsWith("workflow."))
}

function isDashboardQueryKey(queryKey: QueryKey) {
  return queryKey.length === 1 && queryKey[0] === "dashboard"
}

function scheduleDashboardInvalidation(queryClient: QueryClient) {
  const state = dashboardInvalidations.get(queryClient) ?? {
    lastInvalidatedAt: 0,
    pending: false,
    timer: null
  }
  state.pending = true
  dashboardInvalidations.set(queryClient, state)

  if (state.timer) return

  const elapsed = Date.now() - state.lastInvalidatedAt
  const delay = Math.max(0, DASHBOARD_INVALIDATION_MIN_INTERVAL_MS - elapsed)
  state.timer = setTimeout(() => flushDashboardInvalidation(queryClient), delay)
}

function flushDashboardInvalidation(queryClient: QueryClient) {
  const state = dashboardInvalidations.get(queryClient)
  if (!state) return

  state.timer = null
  if (!state.pending) return

  if (queryClient.isFetching({ queryKey: ["dashboard"] }) > 0) {
    state.timer = setTimeout(() => flushDashboardInvalidation(queryClient), DASHBOARD_INVALIDATION_RETRY_MS)
    return
  }

  state.pending = false
  state.lastInvalidatedAt = Date.now()
  void queryClient.invalidateQueries({ queryKey: ["dashboard"] })
}

function applyChatPayloadEvent(queryClient: QueryClient, event: AppEvent) {
  if (event.resource !== "chat" || event.id == null) return false

  const replaceTail = chatReplaceTailPayload(event.payload)
  if (replaceTail) {
    let patched = false
    if (typeof replaceTail.turn_in_flight === "boolean") updateRecentChatTurnCache(queryClient, event.id, { turn_in_flight: replaceTail.turn_in_flight, agent_busy: replaceTail.agent_busy })
    queryClient.setQueriesData<ChatPayload>(
      { queryKey: ["chats", String(event.id)] },
      (current) => {
        if (!current) return current
        if (!Array.isArray(current.messages)) return current
        patched = true

        return {
          ...current,
          turn_in_flight: replaceTail.turn_in_flight ?? current.turn_in_flight,
          agent_busy: replaceTail.agent_busy ?? current.agent_busy,
          queued_messages: replaceTail.queued_messages ?? current.queued_messages,
          messages: replaceMessageTail(current.messages, replaceTail.replace_from_id, replaceTail.messages),
          chat: {
            ...current.chat,
            stop_requested_at: replaceTail.stop_requested_at ?? current.chat.stop_requested_at
          }
        }
      }
    )
    return patched
  }

  const controls = chatControlsPayload(event.payload)
  if (controls) {
    let patched = false
    updateRecentChatTurnCache(queryClient, event.id, { turn_in_flight: controls.turn_in_flight, agent_busy: controls.agent_busy })
    if (controls.scratchpad_items_count !== undefined) {
      updateRecentChatScratchpadCache(queryClient, event.id, controls.scratchpad_items_count)
    }
    queryClient.setQueriesData<ChatPayload>(
      { queryKey: ["chats", String(event.id)] },
      (current) => {
        if (!current || !Array.isArray(current.messages)) return current
        patched = true

        return {
          ...current,
          turn_in_flight: controls.turn_in_flight,
          agent_busy: controls.agent_busy ?? current.agent_busy,
          switching_provider: controls.switching_provider ?? current.switching_provider,
          queued_messages: controls.queued_messages ?? current.queued_messages,
          chat: {
            ...current.chat,
            stop_requested_at: controls.stop_requested_at
          }
        }
      }
    )
    return patched
  }

  const header = chatHeaderPayload(event.payload)
  if (header) {
    let patched = false
    updateRecentChatHeaderCache(queryClient, event.id, header.chat)
    queryClient.setQueriesData<ChatPayload>(
      { queryKey: ["chats", String(event.id)] },
      (current) => {
        if (!current || !Array.isArray(current.messages)) return current
        const recentChats = Array.isArray(current.recent_chats) ? current.recent_chats : []
        patched = true
        return {
          ...current,
          chat: { ...current.chat, ...header.chat },
          recent_chats: recentChats.map((chat) => (
            chat.id === current.chat.id ? { ...chat, ...header.chat } : chat
          ))
        }
      }
    )
    return patched
  }

  const bookmark = chatBookmarkPayload(event.payload)
  if (bookmark) {
    let patched = false
    queryClient.setQueriesData<ChatPayload>(
      { queryKey: ["chats", String(event.id)] },
      (current) => {
        if (!current || !Array.isArray(current.messages)) return current
        const bookmarks = Array.isArray(current.bookmarks) ? current.bookmarks : []
        patched = true
        return { ...current, bookmarks: upsertBookmark(bookmarks, bookmark.bookmark) }
      }
    )
    return patched
  }

  const agentQuestions = chatAgentQuestionsPayload(event.payload)
  if (agentQuestions) {
    let patched = false
    queryClient.setQueriesData<ChatPayload>(
      { queryKey: ["chats", String(event.id)] },
      (current) => {
        if (!current || !Array.isArray(current.messages)) return current
        patched = true
        return { ...current, agent_questions: agentQuestions.agent_questions }
      }
    )
    return patched
  }

  const suggestion = chatSuggestionPayload(event.payload)
  if (suggestion) {
    let patched = false
    queryClient.setQueriesData<ChatPayload>(
      { queryKey: ["chats", String(event.id)] },
      (current) => {
        if (!current || !Array.isArray(current.messages)) return current
        patched = true
        return {
          ...current,
          chat: { ...current.chat, suggested_next_step: suggestion.suggested_next_step }
        }
      }
    )
    return patched
  }

  const pendingAction = chatPendingActionUpdatedPayload(event.payload)
  if (pendingAction) {
    void queryClient.invalidateQueries({ queryKey: ["chats", String(event.id)] })
    return true
  }

  const updateProposal = chatUpdateProposalPayload(event.payload)
  if (updateProposal) {
    void queryClient.invalidateQueries({ queryKey: ["chats", "recent"] })
    void queryClient.invalidateQueries({ queryKey: ["chats", String(event.id)] })
    return true
  }

  const jobStatusChanged = chatJobStatusChangedPayload(event.payload)
  if (jobStatusChanged) {
    if (typeof window !== "undefined") {
      window.dispatchEvent(new CustomEvent("syrus:job-status-changed", {
        detail: { job_id: jobStatusChanged.job_id, chat_session_id: event.id }
      }))
    }
    return true
  }

  return false
}

type ChatReplaceTailPayload = {
  action: "replace_tail"
  replace_from_id: number
  messages: ChatMessageItem[]
  turn_in_flight?: boolean
  agent_busy?: boolean
  stop_requested_at?: string | null
  queued_messages?: ChatQueuedMessage[]
}

type ChatControlsPayload = {
  action: "update_controls"
  turn_in_flight: boolean
  agent_busy?: boolean
  stop_requested_at: string | null
  switching_provider?: boolean
  queued_messages?: ChatQueuedMessage[]
  scratchpad_items_count?: number
}

type ChatHeaderPayload = {
  action: "update_header"
  chat: Partial<Pick<ChatRecord, "title" | "title_pending" | "pinned_context" | "chat_provider" | "effective_chat_provider" | "effective_chat_provider_label" | "provider_availability" | "mode" | "local_daemon_state" | "local_daemon_repo" | "local_daemon_branch" | "repository" | "stop_requested_at" | "cumulative_input_tokens" | "cumulative_output_tokens" | "cumulative_cost_usd" | "coding_checkout_uncommitted">>
}

type ChatBookmarkPayload = {
  action: "upsert_bookmark"
  bookmark: ChatBookmark
}

type ChatAgentQuestionsPayload = {
  action: "update_agent_questions"
  agent_questions: ChatAgentQuestion[]
}

type ChatPendingActionUpdatedPayload = {
  action: "pending_action_updated"
  pending_action_id: number
  chat_message_id: number | null
}

type ChatSuggestionPayload = {
  action: "update_suggestion"
  suggested_next_step: string | null
}

type ChatUpdateProposalPayload = {
  action: "update_proposal"
  proposal_id: number
}

type ChatJobStatusChangedPayload = {
  action: "job_status_changed"
  job_id: number
}

function chatReplaceTailPayload(payload: unknown): ChatReplaceTailPayload | null {
  if (!payload || typeof payload !== "object") return null

  const candidate = payload as Partial<ChatReplaceTailPayload>
  if (candidate.action !== "replace_tail") return null
  if (typeof candidate.replace_from_id !== "number") return null
  const messages = Array.isArray(candidate.messages) ? candidate.messages : Array.isArray((payload as { items?: unknown }).items) ? (payload as { items: unknown[] }).items : null
  if (!isChatMessages(messages)) return null

  return {
    action: "replace_tail",
    replace_from_id: candidate.replace_from_id,
    messages,
    turn_in_flight: typeof candidate.turn_in_flight === "boolean" ? candidate.turn_in_flight : undefined,
    agent_busy: typeof candidate.agent_busy === "boolean" ? candidate.agent_busy : undefined,
    stop_requested_at: typeof candidate.stop_requested_at === "string" || candidate.stop_requested_at === null ? candidate.stop_requested_at : undefined,
    queued_messages: isChatQueuedMessages(candidate.queued_messages) ? candidate.queued_messages : undefined
  }
}

function chatControlsPayload(payload: unknown): ChatControlsPayload | null {
  if (!payload || typeof payload !== "object") return null

  const candidate = payload as Partial<ChatControlsPayload>
  if (candidate.action !== "update_controls") return null
  if (typeof candidate.turn_in_flight !== "boolean") return null
  if (typeof candidate.stop_requested_at !== "string" && candidate.stop_requested_at !== null) return null

  return {
    action: "update_controls",
    turn_in_flight: candidate.turn_in_flight,
    agent_busy: typeof candidate.agent_busy === "boolean" ? candidate.agent_busy : undefined,
    stop_requested_at: candidate.stop_requested_at,
    switching_provider: typeof candidate.switching_provider === "boolean" ? candidate.switching_provider : undefined,
    queued_messages: isChatQueuedMessages(candidate.queued_messages) ? candidate.queued_messages : undefined,
    scratchpad_items_count: Array.isArray((candidate as { scratchpad_items?: unknown }).scratchpad_items)
      ? ((candidate as { scratchpad_items: unknown[] }).scratchpad_items).length
      : undefined
  }
}

function chatHeaderPayload(payload: unknown): ChatHeaderPayload | null {
  if (!payload || typeof payload !== "object") return null

  const candidate = payload as Partial<ChatHeaderPayload>
  if (candidate.action !== "update_header") return null
  if (!candidate.chat || typeof candidate.chat !== "object") return null

  const chat = candidate.chat
  const updates: ChatHeaderPayload["chat"] = {}
  if (typeof chat.title === "string" || chat.title === null) updates.title = chat.title
  if (typeof chat.title_pending === "boolean") updates.title_pending = chat.title_pending
  if (typeof chat.pinned_context === "string" || chat.pinned_context === null) updates.pinned_context = chat.pinned_context
  if (typeof chat.chat_provider === "string") updates.chat_provider = chat.chat_provider
  if (typeof chat.effective_chat_provider === "string") updates.effective_chat_provider = chat.effective_chat_provider
  if (typeof chat.effective_chat_provider_label === "string") updates.effective_chat_provider_label = chat.effective_chat_provider_label
  if (typeof chat.provider_availability === "object" || chat.provider_availability === null) updates.provider_availability = chat.provider_availability
  if (typeof chat.mode === "string" || chat.mode === null) updates.mode = chat.mode as ChatRecord["mode"]
  if (typeof chat.local_daemon_state === "string" || chat.local_daemon_state === null) updates.local_daemon_state = chat.local_daemon_state as ChatRecord["local_daemon_state"]
  if (typeof chat.local_daemon_repo === "string" || chat.local_daemon_repo === null) updates.local_daemon_repo = chat.local_daemon_repo
  if (typeof chat.local_daemon_branch === "string" || chat.local_daemon_branch === null) updates.local_daemon_branch = chat.local_daemon_branch
  if (isChatRepository(chat.repository) || chat.repository === null) updates.repository = chat.repository
  if (typeof chat.stop_requested_at === "string" || chat.stop_requested_at === null) updates.stop_requested_at = chat.stop_requested_at
  if (typeof chat.cumulative_input_tokens === "number") updates.cumulative_input_tokens = chat.cumulative_input_tokens
  if (typeof chat.cumulative_output_tokens === "number") updates.cumulative_output_tokens = chat.cumulative_output_tokens
  if (typeof chat.cumulative_cost_usd === "number") updates.cumulative_cost_usd = chat.cumulative_cost_usd
  if (typeof chat.coding_checkout_uncommitted === "boolean") updates.coding_checkout_uncommitted = chat.coding_checkout_uncommitted

  return {
    action: "update_header",
    chat: updates
  }
}

function chatBookmarkPayload(payload: unknown): ChatBookmarkPayload | null {
  if (!payload || typeof payload !== "object") return null

  const candidate = payload as Partial<ChatBookmarkPayload>
  if (candidate.action !== "upsert_bookmark") return null
  if (!isChatBookmark(candidate.bookmark)) return null

  return {
    action: "upsert_bookmark",
    bookmark: candidate.bookmark
  }
}

function chatAgentQuestionsPayload(payload: unknown): ChatAgentQuestionsPayload | null {
  if (!payload || typeof payload !== "object") return null

  const candidate = payload as Partial<ChatAgentQuestionsPayload>
  if (candidate.action !== "update_agent_questions") return null
  if (!isChatAgentQuestions(candidate.agent_questions)) return null

  return {
    action: "update_agent_questions",
    agent_questions: candidate.agent_questions
  }
}

function chatPendingActionUpdatedPayload(payload: unknown): ChatPendingActionUpdatedPayload | null {
  if (!payload || typeof payload !== "object") return null

  const candidate = payload as Partial<ChatPendingActionUpdatedPayload>
  if (candidate.action !== "pending_action_updated") return null
  if (typeof candidate.pending_action_id !== "number") return null
  if (typeof candidate.chat_message_id !== "number" && candidate.chat_message_id !== null) return null

  return {
    action: "pending_action_updated",
    pending_action_id: candidate.pending_action_id,
    chat_message_id: candidate.chat_message_id
  }
}

function chatSuggestionPayload(payload: unknown): ChatSuggestionPayload | null {
  if (!payload || typeof payload !== "object") return null

  const candidate = payload as Partial<ChatSuggestionPayload>
  if (candidate.action !== "update_suggestion") return null
  if (typeof candidate.suggested_next_step !== "string" && candidate.suggested_next_step !== null) return null

  return {
    action: "update_suggestion",
    suggested_next_step: candidate.suggested_next_step
  }
}

function chatUpdateProposalPayload(payload: unknown): ChatUpdateProposalPayload | null {
  if (!payload || typeof payload !== "object") return null

  const candidate = payload as Partial<ChatUpdateProposalPayload>
  if (candidate.action !== "update_proposal") return null
  if (typeof candidate.proposal_id !== "number") return null

  return { action: "update_proposal", proposal_id: candidate.proposal_id }
}

function chatJobStatusChangedPayload(payload: unknown): ChatJobStatusChangedPayload | null {
  if (!payload || typeof payload !== "object") return null

  const candidate = payload as Partial<ChatJobStatusChangedPayload>
  if (candidate.action !== "job_status_changed") return null
  if (typeof candidate.job_id !== "number") return null

  return { action: "job_status_changed", job_id: candidate.job_id }
}

function isChatMessages(value: unknown): value is ChatMessageItem[] {
  return Array.isArray(value) && value.every((item) => {
    if (!item || typeof item !== "object") return false

    const candidate = item as Partial<ChatMessageItem>
    return candidate.type === "message" && typeof candidate.id === "number"
  })
}

function isChatQueuedMessages(value: unknown): value is ChatQueuedMessage[] {
  return Array.isArray(value) && value.every((item) => {
    if (!item || typeof item !== "object") return false

    const candidate = item as Partial<ChatQueuedMessage>
    return (
      typeof candidate.id === "number" &&
      typeof candidate.text === "string" &&
      (typeof candidate.created_at === "string" || candidate.created_at == null) &&
      typeof candidate.app_update_path === "string" &&
      typeof candidate.app_delete_path === "string"
    )
  })
}

function isChatRepository(value: unknown): value is ChatRepository {
  if (!value || typeof value !== "object") return false

  const candidate = value as Partial<ChatRepository>
  return typeof candidate.id === "number" && typeof candidate.slug === "string"
}

function isChatBookmark(value: unknown): value is ChatBookmark {
  if (!value || typeof value !== "object") return false

  const candidate = value as Partial<ChatBookmark>
  return (
    typeof candidate.id === "number" &&
    typeof candidate.label === "string" &&
    typeof candidate.chat_message_id === "number" &&
    (typeof candidate.anchor_message_id === "number" || candidate.anchor_message_id == null)
  )
}

function isChatAgentQuestions(value: unknown): value is ChatAgentQuestion[] {
  return Array.isArray(value) && value.every((item) => {
    if (!item || typeof item !== "object") return false

    const candidate = item as Partial<ChatAgentQuestion>
    return (
      typeof candidate.id === "number" &&
      typeof candidate.question === "string" &&
      (candidate.options === null || (Array.isArray(candidate.options) && candidate.options.every((option) => typeof option === "string"))) &&
      (typeof candidate.asked_at === "string" || candidate.asked_at == null) &&
      typeof candidate.app_answer_path === "string"
    )
  })
}

function replaceMessageTail(current: ChatMessageItem[], replaceFromId: number, nextMessages: ChatMessageItem[]) {
  return dedupeMessages([
    ...current.filter((message) => message.id < replaceFromId),
    ...nextMessages
  ])
}

function dedupeMessages(messages: ChatMessageItem[]) {
  const seen = new Set<number>()
  const result: ChatMessageItem[] = []

  for (const message of messages) {
    if (seen.has(message.id)) continue

    seen.add(message.id)
    result.push(message)
  }

  return result
}

function upsertBookmark(current: ChatBookmark[], bookmark: ChatBookmark) {
  const next = current.filter((item) => item.id !== bookmark.id)
  next.push(bookmark)
  return next.sort((a, b) => a.chat_message_id - b.chat_message_id || a.id - b.id)
}
