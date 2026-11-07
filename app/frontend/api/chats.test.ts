import { afterEach, describe, expect, it, vi } from "vitest"
import { jsonResponse } from "../testSupport"
import { chatPaths, createChat, createEmptyChat, fetchChats, searchChatJobs, sendChatMessage, uploadChatAttachment } from "./chats"

describe("chat API", () => {
  afterEach(() => {
    vi.restoreAllMocks()
  })

  it("derives stable core chat paths from the chat id", () => {
    expect(chatPaths(42)).toMatchObject({
      app_message_path: "/api/v1/app/chats/42/message",
      app_messages_path: "/api/v1/app/chats/42/messages",
      app_stop_path: "/api/v1/app/chats/42/stop",
      app_coding_diff_path: "/api/v1/app/chats/42/coding_diff"
    })
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

  it("uploads attachment bytes separately and sends only their id", async () => {
    const fetchMock = vi.spyOn(window, "fetch")
    fetchMock.mockResolvedValueOnce(jsonResponse({ id: 9, name: "notes.txt", mime_type: "text/plain", size: 5, url: "/notes" }))
    fetchMock.mockResolvedValueOnce(jsonResponse({ messages: [] }))
    const file = new File(["hello"], "notes.txt", { type: "text/plain" })

    const uploaded = await uploadChatAttachment(4, file)
    await sendChatMessage("/api/v1/app/chats/4/message", "Inspect", [
      { id: uploaded.id, name: uploaded.name, mimeType: uploaded.mime_type, size: uploaded.size, url: uploaded.url }
    ])

    const uploadRequest = fetchMock.mock.calls[0]
    expect(uploadRequest[0]).toBe("/api/v1/app/chats/4/attachments")
    expect((uploadRequest[1]?.body as FormData).get("file")).toBe(file)
    expect(fetchMock.mock.calls[1][1]).toEqual(
      expect.objectContaining({ body: JSON.stringify({ chat_message: { text: "Inspect", attachments: [{ id: 9 }] } }) })
    )
  })

  it("omits the repository when creating an explicitly repositoryless empty chat", async () => {
    const fetchMock = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(createdChatPayload()))

    await createEmptyChat(null, "claude")

    expect(fetchMock).toHaveBeenCalledWith(
      "/api/v1/app/chats",
      expect.objectContaining({
        method: "POST",
        body: JSON.stringify({
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
      unread_only: false,
      per_group: 10
    })

    expect(fetchMock).toHaveBeenCalledWith("/api/v1/app/chats?chat_types=agent%2Cexternal", expect.anything())
  })

  it("adds agent grouping to the recent chats query string", async () => {
    const fetchMock = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({ groups: [], repositories: [] }))

    await fetchChats({
      status: "active",
      group_by: "agent",
      chat_types: [],
      sort_by: "last_activity",
      show_empty_groups: false,
      unread_only: false,
      per_group: 10
    })

    expect(fetchMock).toHaveBeenCalledWith("/api/v1/app/chats?group_by=agent", expect.anything())
  })

  it("adds the unread filter and active chat exception to the recent chats query string", async () => {
    const fetchMock = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({ groups: [], repositories: [] }))

    await fetchChats({ unread_only: true }, 42)

    expect(fetchMock).toHaveBeenCalledWith("/api/v1/app/chats?unread_only=1&active_chat_id=42", expect.anything())
  })

  it("includes active work in job dependency searches", async () => {
    const fetchMock = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({ jobs: [] }))

    await searchChatJobs("running job")

    expect(fetchMock).toHaveBeenCalledWith("/api/v1/app/jobs?q=running+job&fields=picker&include_active_work=true&limit=10", expect.anything())
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
