import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { MemoryRouter } from "react-router-dom"
import { beforeEach, describe, expect, it, vi } from "vitest"
import { updateChatRepository, uploadChatAttachment, type ChatPayload, type ChatPendingAction, type ChatPendingActionGroup } from "../../api/chats"
import { useWalkthroughRecorder } from "../../components/WalkthroughRecorder"
import { reportHandledError } from "../../lib/handledErrorReporting"
import { Compose, PendingActionCarousel } from "./Compose"
import { setDraftAttachments } from "./attachmentDraftStore"

vi.mock("../../components/WalkthroughRecorder", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../../components/WalkthroughRecorder")>()
  return {
    ...actual,
    useWalkthroughRecorder: vi.fn()
  }
})

vi.mock("../../components/ImageAnnotationModal", () => ({
  ImageAnnotationModal: ({ onDone, onExportError }: { onDone: (blob: Blob, shapes: []) => void; onExportError: (error: Error, retry: () => void) => void }) => (
    <div role="dialog">
      <button onClick={() => onDone(new Blob(["annotated"], { type: "image/png" }), [])}>Finish annotation</button>
      <button onClick={() => onDone(new Blob([new Uint8Array(5 * 1024 * 1024 + 1)], { type: "image/png" }), [])}>Finish oversized annotation</button>
      <button onClick={() => onExportError(new Error("export failed"), () => onDone(new Blob(["retry"], { type: "image/png" }), []))}>Fail export</button>
    </div>
  )
}))

vi.mock("../../lib/handledErrorReporting", () => ({ reportHandledError: vi.fn(() => true) }))

vi.mock("../../api/chats", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../../api/chats")>()
  return {
    ...actual,
    updateChatRepository: vi.fn(),
    uploadChatAttachment: vi.fn(async (_chatId: string | number, file: File) => ({
      id: 991,
      name: file.name,
      mime_type: file.type || "application/octet-stream",
      size: file.size,
      url: `/api/v1/app/chats/1/attachments/991/file`
    }))
  }
})

beforeEach(() => {
  setDraftAttachments("1", [])
  vi.mocked(reportHandledError).mockClear()
  vi.mocked(uploadChatAttachment).mockReset().mockImplementation(async (_chatId, file) => ({
    id: 991,
    name: file.name,
    mime_type: file.type || "application/octet-stream",
    size: file.size,
    url: "/api/v1/app/chats/1/attachments/991/file"
  }))
})

function makePayload(): ChatPayload {
  return {
    chat: {
      id: 1,
      title: "Test chat",
      title_pending: false,
      pinned: false,
      pinned_context: null,
      chat_path: "/chats/1",
      repository: null,
      mode: "planning",
      stop_requested_at: null,
      cumulative_input_tokens: 0,
      cumulative_output_tokens: 0,
      cumulative_cost_usd: 0,
      chat_provider_options: []
    },
    chat_available: true,
    switching_provider: false,
    has_more_older: false,
    messages: [],
    bookmarks: [],
    recent_chats: [],
    pending_actions: [],
    agent_questions: [],
    queued_messages: [],
    scratchpad_items: [],
    video_walkthroughs: [],
    preview_panels: [],
    workspace_tabs: [],
    documents_in_scope: [],
    whiteboard: { version: 1, elements: [], appState: {}, files: {} },
    paths: {
      credentials_path: "/credentials",
      repositories_path: "/repositories",
      app_messages_path: "/api/v1/app/chats/1/messages",
      app_message_path: "/api/v1/app/chats/1/message",
      app_rename_path: "/api/v1/app/chats/1/rename",
      app_clear_path: "/api/v1/app/chats/1/messages",
      app_branch_path: "/api/v1/app/chats/1/branch",
      app_share_path: "/api/v1/app/chats/1/share",
      app_enqueue_message_path: "/api/v1/app/chats/1/queued_messages",
      app_scheduled_messages_path: "/api/v1/app/chats/1/scheduled_messages",
      app_stop_path: "/api/v1/app/chats/1/stop",
      app_daemon_connection_path: "/api/v1/app/chats/1/daemon_connection",
      app_switch_provider_path: "/api/v1/app/chats/1/switch_provider",
      app_bookmarks_path: "/api/v1/app/chats/1/bookmarks",
      app_video_walkthroughs_path: "/api/v1/app/chats/1/video_walkthroughs",
      app_whiteboard_path: "/api/v1/app/chats/1/whiteboard",
      app_scratchpad_reorder_path: "/api/v1/app/chats/1/scratchpad_items/reorder"
    },
    gemini_configured: true,
    coding_mode_enabled: false,
    local_mode_enabled: false,
    local_tunnel_connected: false
  }
}

function renderCompose(payload = makePayload()) {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  client.setQueryData(["chats", "1", ""], payload)
  return {
    client,
    ...render(
      <QueryClientProvider client={client}>
        <MemoryRouter>
          <Compose
            chatId="1"
            commandHandlers={{ openBookmarks: vi.fn(), openSettings: vi.fn() }}
            floating={false}
            onNotice={() => {}}
            payload={payload}
            prefix=""
            queryKey={["chats", "1", ""]}
          />
        </MemoryRouter>
      </QueryClientProvider>
    )
  }
}

function pendingAction(id: number, label: string, overrides: Partial<ChatPendingAction> = {}): ChatPendingAction {
  return {
    id,
    label,
    detail: null,
    state: "pending",
    action: "test_action",
    action_type: null,
    app_confirm_path: `/pending_actions/${id}/confirm`,
    app_reject_path: `/pending_actions/${id}/reject`,
    app_cancel_path: `/pending_actions/${id}`,
    ...overrides
  }
}

function pendingActionGroup(id: number, label: string): ChatPendingActionGroup {
  return {
    id,
    label,
    state: "pending",
    members: [{ id: id * 10, label: `${label} member`, state: "pending" }],
    app_confirm_path: `/pending_action_groups/${id}/confirm`,
    app_reject_path: `/pending_action_groups/${id}/reject`,
    app_dismiss_path: `/pending_action_groups/${id}`
  }
}

function renderPendingActionCarousel(items: React.ComponentProps<typeof PendingActionCarousel>["items"]) {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  const view = render(
    <QueryClientProvider client={client}>
      <MemoryRouter>
        <PendingActionCarousel items={items} queryKey={["chats", "1", ""]} onNotice={() => {}} />
      </MemoryRouter>
    </QueryClientProvider>
  )
  return {
    ...view,
    rerenderItems(nextItems: typeof items) {
      view.rerender(
        <QueryClientProvider client={client}>
          <MemoryRouter>
            <PendingActionCarousel items={nextItems} queryKey={["chats", "1", ""]} onNotice={() => {}} />
          </MemoryRouter>
        </QueryClientProvider>
      )
    }
  }
}

describe("pending action carousel", () => {
  it("shows one standalone or permission action at a time and navigates with labelled arrows", () => {
    renderPendingActionCarousel([
      { key: "action:1", type: "action", action: pendingAction(1, "Deploy service") },
      {
        key: "action:2",
        type: "action",
        action: pendingAction(2, "Authorize production access", { request_kind: "authorization_request", authorization_items: [] })
      }
    ])

    expect(screen.getByText("Deploy service")).toBeInTheDocument()
    expect(screen.queryByText("Authorize production access")).not.toBeInTheDocument()
    expect(screen.getByText("Pending actions · 1 of 2")).toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Next pending action" }))

    expect(screen.getByText("Authorize production access")).toBeInTheDocument()
    expect(screen.queryByText("Deploy service")).not.toBeInTheDocument()
    expect(screen.getByText("Pending actions · 2 of 2")).toBeInTheDocument()

    fireEvent.keyDown(screen.getByTestId("pending-action-carousel"), { key: "ArrowLeft" })
    expect(screen.getByText("Deploy service")).toBeInTheDocument()
  })

  it("renders groups as one item and supports intentional horizontal swipes", () => {
    renderPendingActionCarousel([
      { key: "group:3", type: "group", group: pendingActionGroup(3, "Land grouped changes") },
      { key: "action:4", type: "action", action: pendingAction(4, "Restart worker") }
    ])
    const carousel = screen.getByTestId("pending-action-carousel")

    fireEvent.touchStart(carousel, { touches: [{ clientX: 180, clientY: 100 }] })
    fireEvent.touchEnd(carousel, { changedTouches: [{ clientX: 110, clientY: 108 }] })
    expect(screen.getByText("Restart worker")).toBeInTheDocument()

    fireEvent.touchStart(carousel, { touches: [{ clientX: 110, clientY: 100 }] })
    fireEvent.touchEnd(carousel, { changedTouches: [{ clientX: 180, clientY: 170 }] })
    expect(screen.getByText("Restart worker")).toBeInTheDocument()
  })

  it("keeps identity across updates and selects the next remaining item when the current one disappears", () => {
    const first = { key: "action:1", type: "action" as const, action: pendingAction(1, "First action") }
    const second = { key: "action:2", type: "action" as const, action: pendingAction(2, "Second action") }
    const third = { key: "action:3", type: "action" as const, action: pendingAction(3, "Third action") }
    const view = renderPendingActionCarousel([first, second, third])
    fireEvent.click(screen.getByRole("button", { name: "Next pending action" }))

    view.rerenderItems([first, { ...second, action: pendingAction(2, "Updated second action") }, third])
    expect(screen.getByText("Updated second action")).toBeInTheDocument()

    view.rerenderItems([first, third])
    expect(screen.getByText("Third action")).toBeInTheDocument()
  })

  it("uses a count instead of carousel navigation for a single item", () => {
    renderPendingActionCarousel([{ key: "action:1", type: "action", action: pendingAction(1, "Only action") }])

    expect(screen.getByText("Only action")).toBeInTheDocument()
    expect(screen.getByText("1 pending action")).toBeInTheDocument()
    expect(screen.queryByText("1 of 1")).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Previous pending action" })).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Next pending action" })).not.toBeInTheDocument()
  })

  it("keeps an expanded action within the mobile viewport while its carousel controls remain outside the scroll region", () => {
    renderPendingActionCarousel([
      {
        key: "action:1",
        type: "action",
        action: pendingAction(1, "Authorize access", { detail: "Long permission detail. ".repeat(200) })
      }
    ])

    const body = screen.getByTestId("pending-action-carousel-body")
    expect(body).toHaveClass(
      "max-md:max-h-[min(50dvh,calc(var(--chat-visual-viewport-height,100dvh)-12rem))]",
      "max-md:overflow-y-auto",
      "max-md:overscroll-contain"
    )
    expect(screen.getByRole("button", { name: "Collapse pending actions" })).not.toBe(body)
    expect(body).toContainElement(screen.getByText("Long permission detail.", { exact: false }))
  })

  it("collapses the selected card into a one-line summary and restores carousel navigation when expanded", () => {
    renderPendingActionCarousel([
      { key: "action:1", type: "action", action: pendingAction(1, "Deploy service") },
      { key: "action:2", type: "action", action: pendingAction(2, "Restart worker") }
    ])

    const collapse = screen.getByRole("button", { name: "Collapse pending actions" })
    expect(collapse).toHaveAttribute("aria-expanded", "true")
    fireEvent.click(collapse)

    expect(screen.queryByText("Deploy service")).not.toBeInTheDocument()
    expect(screen.getByText("Pending actions · 1 of 2")).toHaveClass("truncate", "whitespace-nowrap")
    expect(screen.queryByRole("button", { name: "Next pending action" })).not.toBeInTheDocument()
    fireEvent.keyDown(screen.getByTestId("pending-action-carousel"), { key: "ArrowRight" })

    const expand = screen.getByRole("button", { name: "Expand pending actions" })
    expect(expand).toHaveAttribute("aria-expanded", "false")
    fireEvent.click(expand)

    expect(screen.getByText("Deploy service")).toBeInTheDocument()
    expect(screen.queryByText("Restart worker")).not.toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Next pending action" })).toBeInTheDocument()
  })
})

describe("Compose repository selection", () => {
  it("invalidates the full chat payload after applying the compact repository patch", async () => {
    vi.mocked(useWalkthroughRecorder).mockReturnValue({
      state: { phase: "idle" },
      elapsed: 0,
      start: vi.fn(),
      stop: vi.fn(),
      annotationAvailable: false,
      annotationHold: false,
      annotationReason: null,
      displaySurface: null,
      drawing: false
    })
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL) => {
        if (String(input) === "/api/v1/app/chats/new") {
          return new Response(JSON.stringify({ repositories: [{ id: 7, slug: "acme/canals" }] }), {
            status: 200,
            headers: { "Content-Type": "application/json" }
          })
        }
        throw new Error(`Unexpected request: ${String(input)}`)
      })
    )
    vi.mocked(updateChatRepository).mockResolvedValue({
      message: "Chat repository updated.",
      chat: { id: 1, repository: { id: 7, slug: "acme/canals" } }
    })

    const { client } = renderCompose()
    const invalidate = vi.spyOn(client, "invalidateQueries")
    const repositoryButton = await screen.findByRole("button", { name: "Repository for new chat" })
    await waitFor(() => expect(repositoryButton).toBeEnabled())
    fireEvent.click(repositoryButton)
    fireEvent.click(await screen.findByRole("option", { name: "acme/canals" }))

    await waitFor(() => expect(invalidate).toHaveBeenCalledWith({ queryKey: ["chats", "1", ""] }))
  })
})

describe("Compose coworker mode", () => {
  it("does not render the Coding/Planning selector for a coworker chat", () => {
    vi.mocked(useWalkthroughRecorder).mockReturnValue({
      state: { phase: "idle" },
      elapsed: 0,
      start: vi.fn(),
      stop: vi.fn(),
      annotationAvailable: false,
      annotationHold: false,
      annotationReason: null,
      displaySurface: null,
      drawing: false
    })
    const payload = makePayload()
    payload.coding_mode_enabled = true
    payload.chat_capabilities = { mode_selection: false }
    renderCompose(payload)

    expect(screen.queryByRole("button", { name: "Change mode" })).not.toBeInTheDocument()
  })
})

describe("Compose walkthrough recorder errors", () => {
  it("renders the recorder error in the composer attachment error slot", async () => {
    vi.mocked(useWalkthroughRecorder).mockReturnValue({
      state: {
        phase: "error",
        message: "This browser cannot record the screen. Drag a video file in instead."
      },
      elapsed: 0,
      start: vi.fn(),
      stop: vi.fn(),
      annotationAvailable: false,
      annotationHold: false,
      annotationReason: null,
      displaySurface: null,
      drawing: false
    })

    renderCompose()

    expect(await screen.findByText("This browser cannot record the screen. Drag a video file in instead.")).toBeInTheDocument()
  })
})

describe("Compose attachments", () => {
  it("leaves the native picker unfiltered so recognized extensionless files can be selected", async () => {
    vi.mocked(useWalkthroughRecorder).mockReturnValue({
      state: { phase: "idle" },
      elapsed: 0,
      start: vi.fn(),
      stop: vi.fn(),
      annotationAvailable: false,
      annotationHold: false,
      annotationReason: null,
      displaySurface: null,
      drawing: false
    })

    renderCompose()

    const input = screen.getByLabelText("Chat attachments")
    expect(input).not.toHaveAttribute("accept")

    fireEvent.change(input, { target: { files: [new File(["FROM ruby"], "Dockerfile", { type: "text/plain" })] } })

    expect(await screen.findByTitle("Dockerfile")).toBeInTheDocument()
    expect(screen.queryByText("Dockerfile is not a supported attachment type.")).not.toBeInTheDocument()
  })

  it("replaces an annotated image with a Blob without fetching a data URL", async () => {
    const fetchMock = vi.fn()
    vi.stubGlobal("fetch", fetchMock)
    renderCompose()

    fireEvent.change(screen.getByLabelText("Chat attachments"), {
      target: { files: [new File(["original"], "screen.png", { type: "image/png" })] }
    })
    await screen.findByTitle("screen.png")
    fireEvent.click(screen.getByRole("button", { name: "Annotate screen.png" }))
    fireEvent.click(screen.getByRole("button", { name: "Finish annotation" }))

    await waitFor(() => expect(vi.mocked(uploadChatAttachment)).toHaveBeenCalledTimes(2))
    const replacement = vi.mocked(uploadChatAttachment).mock.calls[1][1]
    expect(replacement).toBeInstanceOf(File)
    expect(replacement.type).toBe("image/png")
    expect(fetchMock).not.toHaveBeenCalledWith(expect.stringMatching(/^data:/))
  })

  it("keeps the original sendable after replacement failure and recovers on retry with one report", async () => {
    Object.defineProperty(window, "innerWidth", { configurable: true, value: 390 })
    vi.mocked(uploadChatAttachment)
      .mockResolvedValueOnce({ id: 10, name: "screen.png", mime_type: "image/png", size: 8, url: "/original" })
      .mockRejectedValueOnce(new Error("upload failed"))
      .mockResolvedValueOnce({ id: 11, name: "screen.png", mime_type: "image/png", size: 9, url: "/replacement" })
    renderCompose()

    fireEvent.change(screen.getByLabelText("Chat attachments"), {
      target: { files: [new File(["original"], "screen.png", { type: "image/png" })] }
    })
    await screen.findByTitle("screen.png")
    fireEvent.click(screen.getByRole("button", { name: "Annotate screen.png" }))
    fireEvent.click(screen.getByRole("button", { name: "Finish annotation" }))

    expect(await screen.findByRole("alert")).toHaveTextContent("The annotated image could not replace the original attachment.")
    expect(screen.getByRole("button", { name: "Send message" })).not.toBeDisabled()
    expect(screen.getByTitle("screen.png")).toBeInTheDocument()
    expect(reportHandledError).toHaveBeenCalledTimes(1)
    expect(reportHandledError).toHaveBeenCalledWith(expect.any(Error), expect.objectContaining({
      surface: "chat_composer", operation: "replace_attachment", stage: "upload"
    }))

    fireEvent.click(screen.getByRole("button", { name: "Retry" }))
    await waitFor(() => expect(screen.queryByRole("alert")).not.toBeInTheDocument())
    expect(vi.mocked(uploadChatAttachment)).toHaveBeenCalledTimes(3)
    expect(reportHandledError).toHaveBeenCalledTimes(1)
  })

  it("reports Blob export failure once and retries without invalidating the original", async () => {
    renderCompose()
    fireEvent.change(screen.getByLabelText("Chat attachments"), {
      target: { files: [new File(["original"], "screen.png", { type: "image/png" })] }
    })
    await screen.findByTitle("screen.png")
    fireEvent.click(screen.getByRole("button", { name: "Annotate screen.png" }))
    fireEvent.click(screen.getByRole("button", { name: "Fail export" }))

    expect(await screen.findByRole("alert")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Send message" })).not.toBeDisabled()
    expect(reportHandledError).toHaveBeenCalledTimes(1)
    expect(reportHandledError).toHaveBeenCalledWith(expect.any(Error), expect.objectContaining({
      surface: "chat_composer", operation: "replace_attachment", stage: "blob_export"
    }))

    fireEvent.click(screen.getByRole("button", { name: "Retry" }))
    await waitFor(() => expect(screen.queryByRole("alert")).not.toBeInTheDocument())
    expect(vi.mocked(uploadChatAttachment)).toHaveBeenCalledTimes(2)
    expect(reportHandledError).toHaveBeenCalledTimes(1)
  })

  it("keeps the original sendable when the annotated Blob is oversized", async () => {
    renderCompose()
    fireEvent.change(screen.getByLabelText("Chat attachments"), {
      target: { files: [new File(["original"], "screen.png", { type: "image/png" })] }
    })
    await screen.findByTitle("screen.png")
    fireEvent.click(screen.getByRole("button", { name: "Annotate screen.png" }))
    fireEvent.click(screen.getByRole("button", { name: "Finish oversized annotation" }))

    expect(await screen.findByRole("alert")).toHaveTextContent("Each attachment must be 5 MB or smaller.")
    expect(screen.getByRole("button", { name: "Send message" })).not.toBeDisabled()
    expect(vi.mocked(uploadChatAttachment)).toHaveBeenCalledTimes(1)
    expect(reportHandledError).not.toHaveBeenCalled()
  })
})

describe("Compose mention autocomplete", () => {
  it("supports keyboard selection and inserts the selected handle", async () => {
    vi.mocked(useWalkthroughRecorder).mockReturnValue({
      state: { phase: "idle" },
      elapsed: 0,
      start: vi.fn(),
      stop: vi.fn(),
      annotationAvailable: false,
      annotationHold: false,
      annotationReason: null,
      displaySurface: null,
      drawing: false
    })
    const fetchMock = vi.fn().mockResolvedValue({
      ok: true,
      status: 200,
      headers: new Headers({ "content-type": "application/json" }),
      json: async () => ({
        mentionables: [
          {
            id: 1,
            handle: "maya",
            display_name: "Maya",
            subtitle: "Researcher",
            kind: "coworker",
            avatar_url: null,
            avatar_key: null,
            accent_hex: "#E5484D",
            add_to_chat: false
          },
          {
            id: "syrus",
            handle: "syrus",
            display_name: "Syrus",
            subtitle: "Engineer",
            kind: "syrus",
            avatar_url: null,
            avatar_key: null,
            accent_hex: "#FBCFD3",
            add_to_chat: false
          }
        ]
      })
    })
    vi.stubGlobal("fetch", fetchMock)

    renderCompose()
    const composer = screen.getByRole("textbox")
    fireEvent.change(composer, { target: { value: "Ask @" } })
    expect(await screen.findByText("@maya")).toBeInTheDocument()
    expect(screen.getAllByRole("option")).toHaveLength(2)
    fireEvent.keyDown(composer, { key: "ArrowDown" })
    fireEvent.keyDown(composer, { key: "Enter" })

    expect(composer).toHaveValue("Ask @syrus ")
  })

  it("adds an own coworker to the roster before inserting it", async () => {
    vi.mocked(useWalkthroughRecorder).mockReturnValue({
      state: { phase: "idle" },
      elapsed: 0,
      start: vi.fn(),
      stop: vi.fn(),
      annotationAvailable: false,
      annotationHold: false,
      annotationReason: null,
      displaySurface: null,
      drawing: false
    })
    const requests: Array<{ path: string; method?: string }> = []
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
        const path = String(input)
        requests.push({ path, method: init?.method })
        return {
          ok: true,
          status: init?.method === "POST" ? 201 : 200,
          headers: new Headers({ "content-type": "application/json" }),
          json: async () =>
            init?.method === "POST"
              ? { agent: { id: 7 } }
              : {
                  mentionables: [
                    {
                      id: 7,
                      handle: "maya",
                      display_name: "Maya",
                      subtitle: "Researcher",
                      kind: "coworker",
                      avatar_url: null,
                      avatar_key: null,
                      accent_hex: "#FBCFD3",
                      add_to_chat: true
                    }
                  ]
                }
        } as Response
      })
    )

    renderCompose()
    const composer = screen.getByRole("textbox")
    fireEvent.change(composer, { target: { value: "Ask @" } })
    fireEvent.click(await screen.findByRole("option", { name: /@maya/ }))

    expect(await screen.findByRole("textbox")).toHaveValue("Ask @maya ")
    expect(requests).toContainEqual({ path: expect.stringContaining("/chats/1/agents/7"), method: "POST" })
  })
})
