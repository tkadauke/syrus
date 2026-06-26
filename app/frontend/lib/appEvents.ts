import type { QueryClient, QueryKey } from "@tanstack/react-query"
import type { ChatAgentQuestion, ChatBookmark, ChatMessageItem, ChatPayload, ChatQueuedMessage, ChatRecord, ChatRepository } from "../api/chats"
import { updateRecentChatHeaderCache, updateRecentChatTurnCache } from "./chatRecentCache"

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

export function applyAppEvent(queryClient: QueryClient, event: AppEvent) {
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

export function queryKeysFor(event: AppEvent): QueryKey[] {
  switch (event.resource) {
    case "user":
      return [["bootstrap"]]
    case "job":
      return event.id == null ? [["dashboard"], ["jobs"], ["job_run_artifacts"]] : [["dashboard"], ["jobs"], ["jobs", String(event.id)], ["job_run_artifacts", String(event.id)]]
    case "workflow":
      return event.id == null ? [["dashboard"], ["workflows"]] : [["dashboard"], ["workflows"], ["workflows", String(event.id)]]
    case "epic":
      return event.id == null ? [["dashboard"], ["epics"]] : [["dashboard"], ["epics"], ["epics", String(event.id)]]
    case "repository":
      return event.id == null ? [["dashboard"], ["repositories"]] : [["dashboard"], ["repositories"], ["repositories", String(event.id)]]
    case "chat":
      return event.id == null ? [["chats"]] : [["chats"], ["chats", String(event.id)]]
    case "admin_overview":
      return [["admin", "overview"], ["admin", "stuck"]]
    default:
      return []
  }
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
    queryClient.setQueriesData<ChatPayload>(
      { queryKey: ["chats", String(event.id)] },
      (current) => {
        if (!current) return current
        patched = true

        return {
          ...current,
          turn_in_flight: controls.turn_in_flight,
          agent_busy: controls.agent_busy ?? current.agent_busy,
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
        if (!current) return current
        patched = true
        return {
          ...current,
          chat: { ...current.chat, ...header.chat },
          recent_chats: current.recent_chats.map((chat) => (
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
        if (!current) return current
        patched = true
        return { ...current, bookmarks: upsertBookmark(current.bookmarks, bookmark.bookmark) }
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
        if (!current) return current
        patched = true
        return { ...current, agent_questions: agentQuestions.agent_questions }
      }
    )
    return patched
  }

  const pendingAction = chatPendingActionUpdatedPayload(event.payload)
  if (pendingAction) {
    void queryClient.invalidateQueries({ queryKey: ["chats", String(event.id)] })
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
  queued_messages?: ChatQueuedMessage[]
}

type ChatHeaderPayload = {
  action: "update_header"
  chat: Partial<Pick<ChatRecord, "title" | "title_pending" | "pinned_context" | "repository" | "stop_requested_at" | "cumulative_input_tokens" | "cumulative_output_tokens" | "cumulative_cost_usd">>
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
    queued_messages: isChatQueuedMessages(candidate.queued_messages) ? candidate.queued_messages : undefined
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
  if (isChatRepository(chat.repository) || chat.repository === null) updates.repository = chat.repository
  if (typeof chat.stop_requested_at === "string" || chat.stop_requested_at === null) updates.stop_requested_at = chat.stop_requested_at
  if (typeof chat.cumulative_input_tokens === "number") updates.cumulative_input_tokens = chat.cumulative_input_tokens
  if (typeof chat.cumulative_output_tokens === "number") updates.cumulative_output_tokens = chat.cumulative_output_tokens
  if (typeof chat.cumulative_cost_usd === "number") updates.cumulative_cost_usd = chat.cumulative_cost_usd

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
