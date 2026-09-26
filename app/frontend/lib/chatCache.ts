import type { QueryClient, QueryKey } from "@tanstack/react-query"
import { DEFAULT_CHAT_SIDEBAR_SETTINGS, type ChatGroupRecord, type ChatNavRecord, type ChatPayload, type ChatPayloadUpdate, type ChatRecord, type ChatSidebarSettings, type ChatsIndexPayload } from "../api/chats"

export function mergeChatPayloadUpdate(queryClient: QueryClient, queryKey: QueryKey, update: ChatPayloadUpdate) {
  let merged: ChatPayload | undefined

  queryClient.setQueryData<ChatPayload>(queryKey, (current) => {
    if (isFullChatPayload(update)) {
      merged = update
      return update
    }

    if (!current) {
      merged = update as ChatPayload
      return merged
    }

    merged = {
      ...current,
      message: update.message ?? current.message,
      chat: {
        ...current.chat,
        ...update.chat
      }
    }
    return merged
  })

  return merged || (update as ChatPayload)
}

function isFullChatPayload(update: ChatPayloadUpdate): update is ChatPayload {
  return "messages" in update
}

export function recentChatsQueryKey(settings: Partial<ChatSidebarSettings> = {}): QueryKey {
  const normalized = {
    ...DEFAULT_CHAT_SIDEBAR_SETTINGS,
    ...settings
  }
  if (
    normalized.status === DEFAULT_CHAT_SIDEBAR_SETTINGS.status &&
    normalized.group_by === DEFAULT_CHAT_SIDEBAR_SETTINGS.group_by &&
    normalized.sort_by === DEFAULT_CHAT_SIDEBAR_SETTINGS.sort_by &&
    normalized.show_empty_groups === DEFAULT_CHAT_SIDEBAR_SETTINGS.show_empty_groups &&
    normalized.per_group === DEFAULT_CHAT_SIDEBAR_SETTINGS.per_group
  ) {
    return ["chats", "recent"]
  }

  return [
    "chats",
    "recent",
    normalized.status,
    normalized.group_by,
    normalized.sort_by,
    normalized.show_empty_groups,
    normalized.per_group
  ]
}

export function updateRecentChatCache(queryClient: QueryClient, chat: ChatRecord, options: { prepend?: boolean; occurredAt?: string } = {}) {
  queryClient.setQueryData<ChatsIndexPayload>(recentChatsQueryKey(), (current) => {
    if (!current || !Array.isArray(current.groups)) return current

    const existing = current.groups.flatMap((group) => group.chats).find((item) => item.id === chat.id)
    const updated = recentChatRecord(chat, existing, options.occurredAt)
    const targetKey = chatGroupKey(updated)
    const groups = withoutChat(current.groups, chat.id)
    const targetIndex = groups.findIndex((group) => group.key === targetKey)
    const targetGroup = targetIndex >= 0 ? groups[targetIndex] : chatGroupFor(updated)
    const nextChats = options.prepend || !existing
      ? [updated, ...targetGroup.chats]
      : replaceOrPrependChat(targetGroup.chats, updated)
    const nextGroup = { ...targetGroup, chats: nextChats }
    const nextGroups = targetIndex >= 0
      ? [...groups.slice(0, targetIndex), nextGroup, ...groups.slice(targetIndex + 1)]
      : [nextGroup, ...groups]

    return { ...current, groups: nextGroups }
  })
}

export function refreshRecentChats(queryClient: QueryClient) {
  void queryClient.invalidateQueries({ queryKey: ["chats", "recent"] })
}

export function updateChatUnread(queryClient: QueryClient, id: number, unread: boolean) {
  queryClient.setQueriesData<ChatsIndexPayload>({ queryKey: ["chats", "recent"] }, (current) => {
    if (!current) return current
    return {
      ...current,
      groups: current.groups.map((group) => ({
        ...group,
        chats: group.chats.map((chat) => chat.id === id ? { ...chat, unread } : chat)
      }))
    }
  })
}

function recentChatRecord(chat: ChatRecord, existing?: ChatNavRecord, occurredAt = new Date().toISOString()): ChatNavRecord {
  const candidate = chat as ChatNavRecord

  return {
    ...existing,
    ...chat,
    current: candidate.current ?? existing?.current,
    last_message_at: candidate.last_message_at ?? existing?.last_message_at ?? null,
    unread: candidate.unread ?? existing?.unread ?? false,
    pending_proposal_count: candidate.pending_proposal_count ?? existing?.pending_proposal_count ?? 0,
    scratchpad_items_count: candidate.scratchpad_items_count ?? existing?.scratchpad_items_count ?? 0,
    created_at: candidate.created_at ?? existing?.created_at ?? occurredAt,
    updated_at: latestTimestamp(candidate.updated_at, existing?.updated_at, occurredAt)
  }
}

function latestTimestamp(...values: Array<string | null | undefined>) {
  let latest: string | undefined
  let latestValue = 0

  values.forEach((value) => {
    if (!value) return

    const timestamp = Date.parse(value)
    if (Number.isNaN(timestamp) || timestamp < latestValue) return

    latest = value
    latestValue = timestamp
  })

  return latest
}

function replaceOrPrependChat(chats: ChatNavRecord[], chat: ChatNavRecord) {
  const index = chats.findIndex((item) => item.id === chat.id)
  if (index < 0) return [chat, ...chats]

  return [
    ...chats.slice(0, index),
    chat,
    ...chats.slice(index + 1)
  ]
}

export function chatGroupFor(chat: ChatNavRecord): ChatGroupRecord {
  return {
    key: chatGroupKey(chat),
    label: chat.repository?.slug || "General",
    repository_id: chat.repository?.id ?? null,
    chats: [],
    has_more: false
  }
}

export function chatGroupKey(chat: ChatNavRecord) {
  return chat.repository ? `repository-${chat.repository.id}` : "general"
}

function withoutChat(groups: ChatGroupRecord[], chatId: number) {
  return groups.map((group) => ({
    ...group,
    chats: group.chats.filter((item) => item.id !== chatId)
  }))
}
