import { afterEach, describe, expect, it, vi } from "vitest"
import { jsonResponse } from "../testSupport"
import {
  createChat,
  createEmptyChat,
  fetchAllChatMedia,
  fetchChatWhiteboard,
  fetchWhiteboardSnapshots,
  patchChatWhiteboard,
  fetchChats,
  searchChatJobs
} from "./chats"

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

    expect(fetchMock).toHaveBeenCalledWith("/api/v1/app/jobs?q=running+job&include_active_work=true&limit=10", expect.anything())
  })

  it("loads whiteboard files separately from the scene", async () => {
    const fetchMock = vi.spyOn(window, "fetch").mockImplementation(async (input) => {
      const path = String(input)
      if (path.endsWith("/files")) return jsonResponse({ files: { image: { id: "image" } } })
      return jsonResponse({ version: 3, scene_json: { elements: [{ id: "box" }], appState: {} } })
    })

    await expect(fetchChatWhiteboard("/api/v1/app/chats/8/whiteboard")).resolves.toEqual({
      version: 3,
      scene_json: { elements: [{ id: "box" }], appState: {}, files: { image: { id: "image" } } }
    })
    expect(fetchMock).toHaveBeenCalledWith("/api/v1/app/chats/8/whiteboard", expect.anything())
    expect(fetchMock).toHaveBeenCalledWith("/api/v1/app/chats/8/whiteboard/files", expect.anything())
  })

  it("returns the full conflict payload without refetching the whiteboard", async () => {
    const conflict = { version: 4, scene_json: { elements: [{ id: "remote" }], appState: {}, files: {} } }
    const fetchMock = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(conflict, 409))

    await expect(patchChatWhiteboard("/api/v1/app/chats/8/whiteboard", { elements: [], appState: {}, files: {}, expected_version: 3 })).resolves.toEqual({
      status: 409,
      payload: conflict
    })
    expect(fetchMock).toHaveBeenCalledTimes(1)
  })

  it("loads every snapshot page exposed by the paginated endpoint", async () => {
    vi.spyOn(window, "fetch").mockImplementation(async (input) => {
      const page = String(input).includes("page=2") ? 2 : 1
      return jsonResponse({
        whiteboard_snapshots: [{ id: page }],
        pagination: { page, per_page: 30, total: 31, total_pages: 2, has_next_page: page === 1, has_previous_page: page > 1 }
      })
    })

    const result = await fetchWhiteboardSnapshots(8)
    expect(result.whiteboard_snapshots).toEqual([{ id: 1 }, { id: 2 }])
  })

  it("loads every media page for consumers that need complete attachment references", async () => {
    const fetchMock = vi.spyOn(window, "fetch").mockImplementation(async (input) => {
      const page = String(input).includes("image_page=2") ? 2 : 1
      return jsonResponse({
        snapshots: [],
        chat_images: [{ id: page, file_path: `/images/${page}` }],
        typed_artifacts: [{ artifact_index: page - 1, type: "report", title: `Report ${page}` }],
        whiteboard_has_unsaved_content: false,
        pagination: { image_page: page, images_has_more: page === 1, artifact_page: page, artifacts_has_more: page === 1 }
      })
    })

    const result = await fetchAllChatMedia(8)

    expect(result.chat_images.map((image) => image.id)).toEqual([1, 2])
    expect(result.typed_artifacts.map((artifact) => artifact.artifact_index)).toEqual([0, 1])
    expect(fetchMock).toHaveBeenCalledTimes(2)
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
