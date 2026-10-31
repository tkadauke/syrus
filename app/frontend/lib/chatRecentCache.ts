import type { QueryClient } from "@tanstack/react-query"
import type { ChatRecord, ChatsIndexPayload } from "../api/chats"
import { chatGroupFor, chatGroupKeyForUpdate, updateChatUnread } from "./chatCache"

export function updateRecentChatHeaderCache(queryClient: QueryClient, chatId: number | string, updates: Partial<ChatRecord>) {
  queryClient.setQueriesData<ChatsIndexPayload>({ queryKey: ["chats", "recent"] }, (current) => {
    if (!current || !Array.isArray(current.groups)) return current

    const existing = current.groups.flatMap((group) => group.chats).find((chat) => String(chat.id) === String(chatId))
    if (!existing) return current

    const updated = { ...existing, ...updates }
    const targetKey = chatGroupKeyForUpdate(updated, current.groups)
    const groups = current.groups.map((group) => ({
      ...group,
      chats: group.chats.filter((chat) => String(chat.id) !== String(chatId))
    }))
    const targetIndex = groups.findIndex((group) => group.key === targetKey)
    const targetGroup = targetIndex >= 0 ? groups[targetIndex] : chatGroupFor(updated)
    const nextGroup = { ...targetGroup, chats: [updated, ...targetGroup.chats] }
    const nextGroups = targetIndex >= 0 ? [...groups.slice(0, targetIndex), nextGroup, ...groups.slice(targetIndex + 1)] : [nextGroup, ...groups]

    return { ...current, groups: nextGroups }
  })
}

export function updateRecentChatTurnCache(
  queryClient: QueryClient,
  chatId: number | string,
  updates: Pick<ChatRecord, "turn_in_flight"> & Partial<Pick<ChatRecord, "agent_busy">>
) {
  queryClient.setQueriesData<ChatsIndexPayload>({ queryKey: ["chats", "recent"] }, (current) => {
    if (!current || !Array.isArray(current.groups)) return current

    return {
      ...current,
      groups: current.groups.map((group) => ({
        ...group,
        chats: group.chats.map((chat) => (String(chat.id) === String(chatId) ? { ...chat, ...updates } : chat))
      }))
    }
  })
}

export function updateRecentChatMessageStateCache(
  queryClient: QueryClient,
  chatId: number | string,
  updates: Pick<ChatRecord, "turn_in_flight"> & {
    agent_busy?: boolean
    last_message_at: string
    unread: boolean
  }
) {
  updateChatUnread(queryClient, Number(chatId), updates.unread)
  queryClient
    .getQueryCache()
    .findAll({ queryKey: ["chats", "recent"] })
    .forEach((query) => {
      queryClient.setQueryData<ChatsIndexPayload>(query.queryKey, (current) => {
        if (!current || !Array.isArray(current.groups)) return current

        const sortByLastActivity = query.queryKey.length === 2 || query.queryKey[5] === "last_activity"
        return {
          ...current,
          groups: current.groups.map((group) => {
            const existing = group.chats.find((chat) => String(chat.id) === String(chatId))
            if (!existing) return group
            const chats = group.chats.map((chat) => (String(chat.id) === String(chatId) ? { ...chat, ...updates } : chat))
            return {
              ...group,
              chats: sortByLastActivity ? [...chats].sort(compareRecentChatActivity) : chats
            }
          })
        }
      })
    })
}

function compareRecentChatActivity(left: ChatsIndexPayload["groups"][number]["chats"][number], right: ChatsIndexPayload["groups"][number]["chats"][number]) {
  if (left.pinned !== right.pinned) return left.pinned ? -1 : 1

  return timestamp(right.last_message_at || right.created_at) - timestamp(left.last_message_at || left.created_at) || right.id - left.id
}

function timestamp(value: string | null | undefined) {
  const parsed = value ? Date.parse(value) : 0
  return Number.isNaN(parsed) ? 0 : parsed
}

export function updateRecentChatScratchpadCache(queryClient: QueryClient, chatId: number | string, scratchpadItemsCount: number) {
  queryClient.setQueriesData<ChatsIndexPayload>({ queryKey: ["chats", "recent"] }, (current) => {
    if (!current || !Array.isArray(current.groups)) return current

    return {
      ...current,
      groups: current.groups.map((group) => ({
        ...group,
        chats: group.chats.map((chat) => (String(chat.id) === String(chatId) ? { ...chat, scratchpad_items_count: scratchpadItemsCount } : chat))
      }))
    }
  })
}
