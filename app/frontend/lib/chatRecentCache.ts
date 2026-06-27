import type { QueryClient } from "@tanstack/react-query"
import type { ChatGroupRecord, ChatNavRecord, ChatRecord, ChatsIndexPayload } from "../api/chats"

export function upsertRecentChatCache(queryClient: QueryClient, chat: ChatRecord, occurredAt = new Date().toISOString()) {
  queryClient.setQueryData<ChatsIndexPayload>(["chats", "recent"], (current) => {
    if (!current || !Array.isArray(current.groups)) return current

    const existing = current.groups.flatMap((group) => group.chats).find((item) => item.id === chat.id)
    const nextChat: ChatNavRecord = {
      ...chat,
      current: existing?.current ?? false,
      last_message_at: existing?.last_message_at ?? occurredAt,
      unread: existing?.unread ?? false,
      pending_proposal_count: existing?.pending_proposal_count ?? 0,
      created_at: existing?.created_at ?? occurredAt,
      updated_at: occurredAt
    }
    const targetKey = chatGroupKey(nextChat)
    const groups = current.groups.map((group) => ({
      ...group,
      chats: group.chats.filter((item) => item.id !== chat.id)
    }))
    const targetIndex = groups.findIndex((group) => group.key === targetKey)
    const targetGroup = targetIndex >= 0 ? groups[targetIndex] : chatGroupFor(nextChat)
    const nextGroup = { ...targetGroup, chats: [nextChat, ...targetGroup.chats] }
    const nextGroups = targetIndex >= 0
      ? [...groups.slice(0, targetIndex), nextGroup, ...groups.slice(targetIndex + 1)]
      : [nextGroup, ...groups]

    return { ...current, groups: nextGroups }
  })
}

export function updateRecentChatHeaderCache(queryClient: QueryClient, chatId: number | string, updates: Partial<ChatRecord>) {
  queryClient.setQueryData<ChatsIndexPayload>(["chats", "recent"], (current) => {
    if (!current || !Array.isArray(current.groups)) return current

    const existing = current.groups.flatMap((group) => group.chats).find((chat) => String(chat.id) === String(chatId))
    if (!existing) return current

    const updated = { ...existing, ...updates }
    const targetKey = chatGroupKey(updated)
    const groups = current.groups.map((group) => ({
      ...group,
      chats: group.chats.filter((chat) => String(chat.id) !== String(chatId))
    }))
    const targetIndex = groups.findIndex((group) => group.key === targetKey)
    const targetGroup = targetIndex >= 0 ? groups[targetIndex] : chatGroupFor(updated)
    const nextGroup = { ...targetGroup, chats: [updated, ...targetGroup.chats] }
    const nextGroups = targetIndex >= 0
      ? [...groups.slice(0, targetIndex), nextGroup, ...groups.slice(targetIndex + 1)]
      : [nextGroup, ...groups]

    return { ...current, groups: nextGroups }
  })
}

export function updateRecentChatTurnCache(queryClient: QueryClient, chatId: number | string, updates: Pick<ChatRecord, "turn_in_flight"> & Partial<Pick<ChatRecord, "agent_busy">>) {
  queryClient.setQueryData<ChatsIndexPayload>(["chats", "recent"], (current) => {
    if (!current || !Array.isArray(current.groups)) return current

    return {
      ...current,
      groups: current.groups.map((group) => ({
        ...group,
        chats: group.chats.map((chat) => (
          String(chat.id) === String(chatId) ? { ...chat, ...updates } : chat
        ))
      }))
    }
  })
}

function chatGroupFor(chat: ChatNavRecord): ChatGroupRecord {
  return {
    key: chatGroupKey(chat),
    label: chat.repository?.slug || "General",
    repository_id: chat.repository?.id ?? null,
    chats: [],
    has_more: false
  }
}

function chatGroupKey(chat: ChatNavRecord) {
  return chat.repository ? `repository-${chat.repository.id}` : "general"
}
