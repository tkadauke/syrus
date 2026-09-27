import { afterEach, describe, expect, it, vi } from "vitest"
import { jsonResponse } from "../testSupport"
import { createChat, createEmptyChat, fetchChats } from "./chats"

describe("chat API", () => {
  afterEach(() => {
    vi.restoreAllMocks()
  })

  it("posts the selected provider when creating a chat with an initial message", async () => {
    const fetchMock = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(createdChatPayload()))

    await createChat({ repositoryId: "7", text: "Plan this", chatProvider: "codex" })

    expect(fetchMock).toHaveBeenCalledWith(
      "/api/v1/app/chats",
      expect.objectContaining({
        method: "POST",
        body: JSON.stringify({
          repository_id: "7",
          chat_provider: "codex",
          chat_message: { text: "Plan this" }
        })
      })
    )
  })

  it("posts the selected provider when creating an empty chat", async () => {
    const fetchMock = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(createdChatPayload()))

    await createEmptyChat(7, "claude")

    expect(fetchMock).toHaveBeenCalledWith(
      "/api/v1/app/chats",
      expect.objectContaining({
        method: "POST",
        body: JSON.stringify({
          repository_id: 7,
          chat_provider: "claude"
        })
      })
    )
  })

  it("adds selected chat type filters to the recent chats query string", async () => {
    const fetchMock = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({ groups: [], repositories: [] }))

    await fetchChats({
      status: "active",
      group_by: "repository",
      chat_types: ["agent", "external"],
      sort_by: "last_activity",
      show_empty_groups: false,
      per_group: 10
    })

    expect(fetchMock).toHaveBeenCalledWith(
      "/api/v1/app/chats?chat_types=agent%2Cexternal",
      expect.anything()
    )
  })
})

function createdChatPayload() {
  return {
    message: "Chat created.",
    redirect_to: "/chats/1",
    chat: {
      id: 1,
      title: null,
      title_pending: false,
      pinned: false,
      pinned_context: null,
      chat_provider: "claude",
      chat_path: "/chats/1",
      repository: null,
      stop_requested_at: null,
      cumulative_input_tokens: 0,
      cumulative_output_tokens: 0,
      cumulative_cost_usd: 0
    }
  }
}
