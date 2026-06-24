import type { QueryClient } from "@tanstack/react-query"
import type { ChatNavRecord, ChatRecord, ChatsIndexPayload } from "../api/chats"

export function updateRecentChatCache(queryClient: QueryClient, chat: ChatRecord, options: { prepend?: boolean } = {}) {
  queryClient.setQueryData<ChatsIndexPayload>(["chats", "recent"], (current) => {
    if (!current || !Array.isArray(current.chats)) return current

    const existing = current.chats.find((item) => item.id === chat.id)
    const updated = recentChatRecord(chat, existing)
    const chats = current.chats.filter((item) => item.id !== chat.id)

    if (options.prepend || !existing) {
      return { ...current, chats: [updated, ...chats] }
    }

    const index = current.chats.findIndex((item) => item.id === chat.id)
    return {
      ...current,
      chats: [
        ...current.chats.slice(0, index),
        updated,
        ...current.chats.slice(index + 1)
      ]
    }
  })
}

export function refreshRecentChats(queryClient: QueryClient) {
  void queryClient.invalidateQueries({ queryKey: ["chats", "recent"] })
}

function recentChatRecord(chat: ChatRecord, existing?: ChatNavRecord): ChatNavRecord {
  const candidate = chat as ChatNavRecord

  return {
    ...existing,
    ...chat,
    current: candidate.current ?? existing?.current,
    last_message_at: candidate.last_message_at ?? existing?.last_message_at ?? null,
    unread: candidate.unread ?? existing?.unread ?? false,
    created_at: candidate.created_at ?? existing?.created_at,
    updated_at: candidate.updated_at ?? existing?.updated_at ?? new Date().toISOString()
  }
}
