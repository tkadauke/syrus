import { QueryClient } from "@tanstack/react-query"
import { describe, expect, it, vi } from "vitest"
import { updateRecentChatCache } from "./chatCache"
import type { ChatNavRecord } from "../api/chats"

describe("updateRecentChatCache", () => {
  it("moves the active chat to the top and records fresh activity", () => {
    vi.useFakeTimers()
    vi.setSystemTime(new Date("2026-06-25T12:00:00Z"))

    const queryClient = new QueryClient()
    queryClient.setQueryData(["chats", "recent"], {
      repositories: [],
      chats: [
        chatRecord({ id: 1, title: "Newer", lastMessageAt: "2026-06-25T11:00:00Z" }),
        chatRecord({ id: 2, title: "Active", lastMessageAt: "2026-06-24T11:00:00Z", updatedAt: "2026-06-24T11:00:00Z" })
      ]
    })

    updateRecentChatCache(queryClient, { ...chatRecord({ id: 2, title: "Active", lastMessageAt: "2026-06-24T11:00:00Z" }) }, { prepend: true })

    const updated = queryClient.getQueryData<{ chats: ChatNavRecord[] }>(["chats", "recent"])
    expect(updated?.chats.map((chat) => chat.id)).toEqual([2, 1])
    expect(updated?.chats[0].updated_at).toBe("2026-06-25T12:00:00.000Z")

    vi.useRealTimers()
  })
})

function chatRecord({ id, title, lastMessageAt, updatedAt }: { id: number; title: string; lastMessageAt: string | null; updatedAt?: string }): ChatNavRecord {
  return {
    id,
    title,
    title_pending: false,
    pinned_context: null,
    chat_path: `/chats/${id}`,
    repository: null,
    stop_requested_at: null,
    cumulative_input_tokens: 0,
    cumulative_output_tokens: 0,
    cumulative_cost_usd: 0,
    current: false,
    last_message_at: lastMessageAt,
    unread: false,
    created_at: "2026-06-20T10:00:00Z",
    updated_at: updatedAt || lastMessageAt || "2026-06-20T10:00:00Z"
  }
}
