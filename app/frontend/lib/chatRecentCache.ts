import type { QueryClient } from "@tanstack/react-query"
import type { ChatNavRecord, ChatRecord, ChatsIndexPayload } from "../api/chats"

export function upsertRecentChatCache(queryClient: QueryClient, chat: ChatRecord, occurredAt = new Date().toISOString()) {
  queryClient.setQueryData<ChatsIndexPayload>(["chats", "recent"], (current) => {
    if (!current || !Array.isArray(current.chats)) return current

    const existing = current.chats.find((item) => item.id === chat.id)
    const nextChat: ChatNavRecord = {
      ...chat,
      current: existing?.current ?? false,
      last_message_at: existing?.last_message_at ?? occurredAt,
      unread: existing?.unread ?? false,
      created_at: existing?.created_at ?? occurredAt,
      updated_at: occurredAt
    }

    return {
      ...current,
      chats: [
        nextChat,
        ...current.chats.filter((item) => item.id !== chat.id)
      ]
    }
  })
}

export function updateRecentChatHeaderCache(queryClient: QueryClient, chatId: number | string, updates: Partial<ChatRecord>) {
  queryClient.setQueryData<ChatsIndexPayload>(["chats", "recent"], (current) => {
    if (!current || !Array.isArray(current.chats)) return current

    let changed = false
    const chats = current.chats.map((chat) => {
      if (String(chat.id) !== String(chatId)) return chat

      changed = true
      return { ...chat, ...updates }
    })

    return changed ? { ...current, chats } : current
  })
}
