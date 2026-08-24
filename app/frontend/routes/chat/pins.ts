import { useQuery } from "@tanstack/react-query"
import { fetchChatMessagePins, type ChatMessagePin } from "../../api/chats"
import { appendSearch } from "./utils"

// Shared pins query used by both PinControl (per-message toggle state) and
// PinnedMessagesBar (top-of-chat preview) — same query key so React Query
// dedupes the request and both surfaces stay in sync off one cache entry.

export function chatPinsQueryKey(chatId: number | string, search: string) {
  return ["chat-pins", String(chatId), search] as const
}

export function chatPinsPath(chatId: number | string) {
  return `/api/v1/app/chats/${encodeURIComponent(String(chatId))}/pins`
}

export function useChatPins(chatId: number | string, search: string) {
  return useQuery({
    queryKey: chatPinsQueryKey(chatId, search),
    queryFn: ({ signal }) => fetchChatMessagePins(appendSearch(chatPinsPath(chatId), search), { signal })
  })
}

// Whether the workspace's Pinned tab should be offered at all. Assumes
// visible while the pins query hasn't resolved yet, so a stored "pinned"
// tab preference isn't yanked away before we actually know there's nothing
// pinned — it only hides once the query confirms zero pins.
export function useHasPins(chatId: number | string, search: string) {
  const pinsQuery = useChatPins(chatId, search)
  if (pinsQuery.isPending) return true

  return (pinsQuery.data?.pins?.length ?? 0) > 0
}

// Backend already orders pins by creation time ascending; take the newest N
// (highest id) and return them newest-first for display.
export function newestPins(pins: ChatMessagePin[], count: number) {
  return [...pins].sort((a, b) => b.id - a.id).slice(0, count)
}
