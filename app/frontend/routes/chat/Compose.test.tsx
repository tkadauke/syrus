import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { MemoryRouter } from "react-router-dom"
import { describe, expect, it, vi } from "vitest"
import { updateChatRepository, type ChatPayload, type ChatPendingAction, type ChatPendingActionGroup } from "../../api/chats"
import { useWalkthroughRecorder } from "../../components/WalkthroughRecorder"
import { Compose, PendingActionCarousel } from "./Compose"

vi.mock("../../components/WalkthroughRecorder", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../../components/WalkthroughRecorder")>()
  return {
    ...actual,
    useWalkthroughRecorder: vi.fn()
  }
})

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
    expect(screen.getByText("1 of 2")).toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Next pending action" }))

    expect(screen.getByText("Authorize production access")).toBeInTheDocument()
    expect(screen.queryByText("Deploy service")).not.toBeInTheDocument()
    expect(screen.getByText("2 of 2")).toBeInTheDocument()

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

  it("hides navigation controls for a single item", () => {
    renderPendingActionCarousel([{ key: "action:1", type: "action", action: pendingAction(1, "Only action") }])

    expect(screen.getByText("1 of 1")).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Previous pending action" })).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Next pending action" })).not.toBeInTheDocument()
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
    payload.coworker_chat = true
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
