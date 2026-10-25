import { useQuery } from "@tanstack/react-query"
import { fetchChatBookmarks } from "../../api/chats"
import { appendSearch } from "./utils"

export function chatBookmarksQueryKey(chatId: number | string, search: string) {
  return ["chat-bookmarks", String(chatId), search] as const
}

export function chatBookmarksQueryPrefix(chatId: number | string) {
  return ["chat-bookmarks", String(chatId)] as const
}

export function chatBookmarksPath(chatId: number | string) {
  return `/api/v1/app/chats/${encodeURIComponent(String(chatId))}/bookmarks`
}

export function useChatBookmarks(chatId: number | string, search: string, enabled = true) {
  return useQuery({
    queryKey: chatBookmarksQueryKey(chatId, search),
    queryFn: ({ signal }) => fetchChatBookmarks(appendSearch(chatBookmarksPath(chatId), search), { signal }),
    enabled,
    staleTime: Infinity
  })
}
