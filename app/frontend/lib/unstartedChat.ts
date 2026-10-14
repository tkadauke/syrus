import type { QueryClient, QueryKey } from "@tanstack/react-query"
import type { ChatNavRecord, ChatsIndexPayload } from "../api/chats"

export function firstUnstartedChat(payload: ChatsIndexPayload | undefined): ChatNavRecord | null {
  if (!payload || !Array.isArray(payload.groups)) return null

  return payload.groups.flatMap((group) => group.chats).find((chat) => chat.last_message_at == null) || null
}

export function firstUnstartedChatInRecentCaches(queryClient: QueryClient): ChatNavRecord | null {
  const recentQueries = queryClient.getQueryCache().findAll({ queryKey: ["chats", "recent"] })

  for (const query of recentQueries) {
    if (!recentChatQueryCanReuseUnstartedChat(query.queryKey)) continue

    const unstartedChat = firstUnstartedChat(query.state.data as ChatsIndexPayload | undefined)
    if (unstartedChat) return unstartedChat
  }

  return null
}

function recentChatQueryCanReuseUnstartedChat(queryKey: QueryKey) {
  return queryKey.length === 2 || queryKey[2] !== "hidden"
}
