import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import { beforeEach, describe, expect, it, vi } from "vitest"
import { MemoryRouter, Route, Routes } from "react-router-dom"
import { ChatRoute, storedWorkspaceCollapsed } from "./Chat"

describe("storedWorkspaceCollapsed", () => {
  beforeEach(() => {
    window.localStorage.clear()
  })

  it("defaults to collapsed when the preference is absent", () => {
    expect(storedWorkspaceCollapsed()).toBe(true)
  })

  it("returns the stored boolean preference", () => {
    window.localStorage.setItem("syrus.chat.workspace.collapsed", "false")
    expect(storedWorkspaceCollapsed()).toBe(false)

    window.localStorage.setItem("syrus.chat.workspace.collapsed", "true")
    expect(storedWorkspaceCollapsed()).toBe(true)
  })
})

describe("ChatWorkspace panel collapse", () => {
  beforeEach(() => {
    window.localStorage.clear()
    window.localStorage.setItem("syrus.chat.workspace.tab", "context")
    mockDesktopViewport()
  })

  it("renders a collapsed strip by default and toggles the workspace panel", async () => {
    vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/mark_read" && init?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }

      return Promise.resolve(jsonResponse(chatPayload()))
    })

    renderRoute()

    expect(await screen.findByText("Discuss aqueducts.")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Open workspace panel" })).toBeInTheDocument()
    expect(screen.queryByRole("complementary", { name: "Chat workspace" })).not.toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Open workspace panel" }))

    expect(screen.getByRole("complementary", { name: "Chat workspace" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Close workspace panel" })).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Open workspace panel" })).not.toBeInTheDocument()
    expect(window.localStorage.getItem("syrus.chat.workspace.collapsed")).toBe("false")

    fireEvent.click(screen.getByRole("button", { name: "Close workspace panel" }))

    expect(screen.queryByRole("complementary", { name: "Chat workspace" })).not.toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Open workspace panel" })).toBeInTheDocument()
    await waitFor(() => {
      expect(window.localStorage.getItem("syrus.chat.workspace.collapsed")).toBe("true")
    })
  })
})

describe("chat compose drafts", () => {
  beforeEach(() => {
    window.localStorage.clear()
    mockDesktopViewport()
  })

  it("restores and persists the saved draft for the current chat", async () => {
    window.localStorage.setItem("syrus.chat.draft.8", "Please inspect the channel routing.")
    vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/mark_read" && init?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }

      return Promise.resolve(jsonResponse(chatPayload()))
    })

    renderRoute()

    const textarea = await screen.findByPlaceholderText("Ask about this repository...")
    expect(textarea).toHaveValue("Please inspect the channel routing.")

    fireEvent.change(textarea, { target: { value: "Follow the operator chat draft." } })

    await waitFor(() => {
      expect(window.localStorage.getItem("syrus.chat.draft.8")).toBe("Follow the operator chat draft.")
    })
  })
})

describe("chat pending proposal jump banner", () => {
  beforeEach(() => {
    window.localStorage.clear()
    mockDesktopViewport()
    Object.defineProperty(HTMLElement.prototype, "scrollIntoView", {
      configurable: true,
      value: vi.fn()
    })
  })

  it("shows the number of pending proposals above compose", async () => {
    vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/mark_read" && init?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }

      return Promise.resolve(jsonResponse(chatPayload({
        messages: [
          messageWithProposal(9, proposal({ id: 1, title: "Survey aqueduct route" })),
          messageWithProposal(10, proposal({ id: 2, title: "Draft build plan" }))
        ]
      })))
    })

    renderRoute()

    expect(await screen.findByText("2 pending proposals")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Jump (1 of 2)" })).toBeInTheDocument()
  })

  it("jumps through pending proposal messages in order", async () => {
    vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/mark_read" && init?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }

      return Promise.resolve(jsonResponse(chatPayload({
        messages: [
          messageWithProposal(9, proposal({ id: 1, title: "Survey aqueduct route" })),
          messageWithProposal(10, proposal({ id: 2, title: "Draft build plan" }))
        ]
      })))
    })

    renderRoute()

    const jump = await screen.findByRole("button", { name: "Jump (1 of 2)" })
    const firstScroll = vi.fn()
    const secondScroll = vi.fn()
    Object.defineProperty(document.getElementById("chat_message_9"), "scrollIntoView", {
      configurable: true,
      value: firstScroll
    })
    Object.defineProperty(document.getElementById("chat_message_10"), "scrollIntoView", {
      configurable: true,
      value: secondScroll
    })

    fireEvent.click(jump)

    expect(firstScroll).toHaveBeenCalledWith({ behavior: "smooth", block: "start" })
    expect(secondScroll).not.toHaveBeenCalled()

    fireEvent.click(await screen.findByRole("button", { name: "Jump (2 of 2)" }))

    expect(secondScroll).toHaveBeenCalledWith({ behavior: "smooth", block: "start" })
  })

  it("does not show the banner for resolved proposals", async () => {
    vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/mark_read" && init?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }

      return Promise.resolve(jsonResponse(chatPayload({
        messages: [
          messageWithProposal(9, proposal({ proposed: false, resolved: true, state: "confirmed", state_label: "Confirmed" }))
        ]
      })))
    })

    renderRoute()

    expect(await screen.findByText("Discuss proposal 9.")).toBeInTheDocument()
    expect(screen.queryByText("1 pending proposal")).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Jump ↑" })).not.toBeInTheDocument()
  })
})

describe("chat proposal cards", () => {
  beforeEach(() => {
    window.localStorage.clear()
    mockDesktopViewport()
  })

  it("labels Epic confirmation without Jobs when the proposal has no child Jobs", async () => {
    vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/mark_read" && init?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }

      return Promise.resolve(jsonResponse(chatPayload({
        messages: [
          messageWithProposal(9, proposal({
            kind: "epic",
            kind_label: "Epic",
            title: "Plan onboarding",
            slug: "EPIC-DRAFT-1",
            epic_bundle: true,
            active_children_count: 0,
            children: []
          }))
        ]
      })))
    })

    renderRoute()

    expect(await screen.findByRole("button", { name: "Confirm Epic" })).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Confirm Epic and Jobs" })).not.toBeInTheDocument()
  })

  it("labels Epic confirmation with Jobs when the proposal has child Jobs", async () => {
    vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/mark_read" && init?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }

      return Promise.resolve(jsonResponse(chatPayload({
        messages: [
          messageWithProposal(9, proposal({
            kind: "epic",
            kind_label: "Epic",
            title: "Plan onboarding",
            slug: "EPIC-DRAFT-1",
            epic_bundle: true,
            active_children_count: 1,
            children: [
              {
                id: 11,
                title: "Build first step",
                slug: "JOB-DRAFT-1",
                body: "Create the first onboarding step.",
                state: "proposed",
                state_label: "Pending",
                proposed: true,
                repository_slug: "acme/widgets",
                dependencies: [],
                app_reject_path: "/api/v1/app/chats/8/proposals/1/children/11/reject"
              }
            ]
          }))
        ]
      })))
    })

    renderRoute()

    expect(await screen.findByRole("button", { name: "Confirm Epic and Jobs" })).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Confirm Epic" })).not.toBeInTheDocument()
  })
})

describe("chat compose image attachments", () => {
  beforeEach(() => {
    window.localStorage.clear()
    mockDesktopViewport()
  })

  it("shows an edit glyph on the annotate thumbnail affordance", async () => {
    vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/mark_read" && init?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }

      return Promise.resolve(jsonResponse(chatPayload()))
    })

    renderRoute()

    await screen.findByPlaceholderText("Ask about this repository...")
    fireEvent.change(screen.getByLabelText("Chat attachments"), { target: { files: [new File(["pixels"], "screen.png", { type: "image/png" })] } })

    const annotateButton = await screen.findByRole("button", { name: "Annotate screen.png" })
    expect(annotateButton.querySelector("svg")).toBeInTheDocument()
    expect(annotateButton.querySelector("span")).toHaveClass("group-hover:opacity-100", "group-focus-visible:opacity-100")
    expect(screen.getByRole("button", { name: "Remove screen.png" }).querySelector("svg")).toBeInTheDocument()
  })
})

describe("chat message image attachments", () => {
  beforeEach(() => {
    window.localStorage.clear()
    mockDesktopViewport()
  })

  it("renders image thumbnails and opens a dismissible lightbox", async () => {
    vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/mark_read" && init?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }

      return Promise.resolve(jsonResponse(chatPayload({
        messages: [
          {
            type: "message",
            id: 9,
            role: "user",
            tool_name: null,
            content: { text: "Inspect this." },
            text: "Inspect this.",
            bookmarkable: true,
            attachments: [
              { name: "diagram.png", mime_type: "image/png", data: "cGl4ZWxz" },
              { name: "notes.pdf", mime_type: "application/pdf", data: "cGRm" }
            ]
          }
        ]
      })))
    })

    renderRoute()

    const thumbnail = await screen.findByRole("button", { name: "Open diagram.png" })
    expect(screen.getByAltText("diagram.png")).toHaveAttribute("src", "data:image/png;base64,cGl4ZWxz")
    expect(screen.queryByText("notes.pdf")).not.toBeInTheDocument()

    fireEvent.click(thumbnail)

    expect(screen.getByRole("dialog", { name: "diagram.png" })).toBeInTheDocument()

    fireEvent.keyDown(window, { key: "Escape" })

    await waitFor(() => {
      expect(screen.queryByRole("dialog", { name: "diagram.png" })).not.toBeInTheDocument()
    })
  })

  it("shows all shared images in the media tab with downloads and lightbox preview", async () => {
    window.localStorage.setItem("syrus.chat.workspace.collapsed", "false")
    window.localStorage.setItem("syrus.chat.workspace.tab", "context")
    vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/mark_read" && init?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }

      return Promise.resolve(jsonResponse(chatPayload({
        messages: [
          {
            type: "message",
            id: 9,
            role: "user",
            tool_name: null,
            content: { text: "First image." },
            text: "First image.",
            bookmarkable: true,
            attachments: [
              { name: "diagram.png", mime_type: "image/png", data: "cGl4ZWxz" },
              { name: "notes.pdf", mime_type: "application/pdf", data: "cGRm" }
            ]
          },
          {
            type: "message",
            id: 10,
            role: "assistant",
            tool_name: null,
            content: { text: "Second image." },
            text: "Second image.",
            bookmarkable: true,
            attachments: [
              { name: "mockup.jpg", mime_type: "image/jpeg", data: "anBlZw==" }
            ]
          }
        ]
      })))
    })

    renderRoute()

    fireEvent.click(await screen.findByRole("button", { name: "Media" }))

    const workspace = screen.getByRole("complementary", { name: "Chat workspace" })
    expect(within(workspace).getByText("diagram.png")).toBeInTheDocument()
    expect(within(workspace).getByText("mockup.jpg")).toBeInTheDocument()
    expect(within(workspace).queryByText("notes.pdf")).not.toBeInTheDocument()

    const download = within(workspace).getByRole("link", { name: "Download diagram.png" })
    expect(download).toHaveAttribute("href", "data:image/png;base64,cGl4ZWxz")
    expect(download).toHaveAttribute("download", "diagram.png")

    fireEvent.click(within(workspace).getByRole("button", { name: "Open mockup.jpg" }))

    expect(screen.getByRole("dialog", { name: "mockup.jpg" })).toBeInTheDocument()
  })

  it("shows an empty media tab state when no images have been shared", async () => {
    window.localStorage.setItem("syrus.chat.workspace.collapsed", "false")
    window.localStorage.setItem("syrus.chat.workspace.tab", "media")
    vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/mark_read" && init?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }

      return Promise.resolve(jsonResponse(chatPayload()))
    })

    renderRoute()

    expect(await screen.findByText("No media shared yet.")).toBeInTheDocument()
  })

  it("includes media in the mobile chat tab list", async () => {
    mockMobileViewport()
    vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/mark_read" && init?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }

      return Promise.resolve(jsonResponse(chatPayload()))
    })

    renderRoute()

    expect(await screen.findByRole("button", { name: "Media" })).toBeInTheDocument()
  })
})

describe("chat attachment detach confirmation", () => {
  beforeEach(() => {
    window.localStorage.clear()
    window.localStorage.setItem("syrus.chat.workspace.collapsed", "false")
    window.localStorage.setItem("syrus.chat.workspace.tab", "context")
    mockDesktopViewport()
  })

  it("does not detach an attachment on the first click", async () => {
    const fetchMock = mockChatAttachmentFetch()

    renderRoute()

    fireEvent.click(await screen.findByRole("button", { name: "Runbook.md" }))

    expect(screen.getByRole("button", { name: "Detach Runbook.md?" })).toBeInTheDocument()
    expect(detachRequests(fetchMock)).toHaveLength(0)
  })

  it("detaches an attachment on the second click of the same button", async () => {
    const fetchMock = mockChatAttachmentFetch()

    renderRoute()

    fireEvent.click(await screen.findByRole("button", { name: "Runbook.md" }))
    fireEvent.click(screen.getByRole("button", { name: "Detach Runbook.md?" }))

    await waitFor(() => {
      expect(detachRequests(fetchMock)).toHaveLength(1)
    })
  })

  it("cancels a pending detach without calling the API", async () => {
    const fetchMock = mockChatAttachmentFetch()

    renderRoute()

    fireEvent.click(await screen.findByRole("button", { name: "Runbook.md" }))
    fireEvent.click(screen.getByRole("button", { name: "Cancel" }))

    expect(screen.getByRole("button", { name: "Runbook.md" })).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Detach Runbook.md?" })).not.toBeInTheDocument()
    expect(detachRequests(fetchMock)).toHaveLength(0)
  })
})

describe("repositoryless chat compose", () => {
  beforeEach(() => {
    window.localStorage.clear()
    mockDesktopViewport()
  })

  it("invites open-ended chat and allows submit without an attached repository", async () => {
    vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/mark_read" && init?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }

      return Promise.resolve(jsonResponse(chatPayload({ chat: { repository: null }, messages: [] })))
    })

    renderRoute()

    expect(await screen.findByText("Ask anything, or attach a repository for code context.")).toBeInTheDocument()
    const textarea = await screen.findByPlaceholderText("Ask anything — or attach a repository to give the agent context...")
    fireEvent.change(textarea, { target: { value: "Can you help me plan a release?" } })

    expect(screen.getByRole("button", { name: "Send" })).toBeEnabled()
  })
})

function renderRoute() {
  render(
    <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
      <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
        <Routes>
          <Route element={<ChatRoute />} path="/app-shell/chats/:id" />
        </Routes>
      </MemoryRouter>
    </QueryClientProvider>
  )
}

function mockDesktopViewport() {
  Object.defineProperty(window, "matchMedia", {
    configurable: true,
    writable: true,
    value: vi.fn((query: string) => ({
      matches: query.includes("min-width: 1024px"),
      media: query,
      onchange: null,
      addEventListener: vi.fn(),
      removeEventListener: vi.fn(),
      addListener: vi.fn(),
      removeListener: vi.fn(),
      dispatchEvent: vi.fn()
    }))
  })
}

function mockMobileViewport() {
  Object.defineProperty(window, "matchMedia", {
    configurable: true,
    writable: true,
    value: vi.fn((query: string) => ({
      matches: !query.includes("min-width: 1024px"),
      media: query,
      onchange: null,
      addEventListener: vi.fn(),
      removeEventListener: vi.fn(),
      addListener: vi.fn(),
      removeListener: vi.fn(),
      dispatchEvent: vi.fn()
    }))
  })
}

function mockChatAttachmentFetch() {
  return vi.spyOn(window, "fetch").mockImplementation((input, init) => {
    const path = String(input)
    if (path === "/api/v1/app/chats/8/mark_read" && init?.method === "PATCH") {
      return Promise.resolve(new Response(null, { status: 204 }))
    }

    return Promise.resolve(jsonResponse(chatPayload({
      attachment_groups: {
        documents: [
          { id: 31, label: "Runbook.md", app_detach_path: "/api/v1/app/chats/8/attachments/31" }
        ]
      }
    })))
  })
}

function detachRequests(fetchMock: ReturnType<typeof vi.spyOn>) {
  return fetchMock.mock.calls.filter((call: unknown[]) => {
    const input = call[0]
    const init = call[1] as RequestInit | undefined
    return String(input) === "/api/v1/app/chats/8/attachments/31" && init?.method === "DELETE"
  })
}

function messageWithProposal(id: number, chatProposal: Record<string, unknown>) {
  return {
    type: "message",
    id,
    role: "assistant",
    tool_name: null,
    content: { text: `Discuss proposal ${id}.` },
    text: `Discuss proposal ${id}.`,
    bookmarkable: true,
    proposal: chatProposal
  }
}

function proposal(overrides: Record<string, unknown> = {}) {
  return {
    id: 1,
    kind: "job",
    kind_label: "Job",
    state: "proposed",
    state_label: "Pending",
    title: "Survey aqueduct route",
    slug: "JOB-DRAFT-1",
    body: "Inspect the aqueduct route.",
    proposed: true,
    resolved: false,
    epic_bundle: false,
    scoped_repository_slug: null,
    dependency_slugs: [],
    dependencies: [],
    has_dependencies: false,
    target_epic_label: null,
    app_confirm_path: "/api/v1/app/chats/8/proposals/1/confirm",
    app_reject_path: "/api/v1/app/chats/8/proposals/1/reject",
    materialized_label: null,
    materialized_path: null,
    materialized: null,
    ...overrides
  }
}

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } })
}

function chatPayload(overrides: { chat?: Record<string, unknown>; messages?: Array<Record<string, unknown>>; attachment_groups?: Record<string, Array<Record<string, unknown>>> } = {}) {
  return {
    chat: {
      id: 8,
      title: "Aqueduct planning",
      title_pending: false,
      pinned_context: null,
      chat_path: "/chats/8",
      repository: { id: 3, slug: "acme/widgets", repository_path: "/repositories/3" },
      stop_requested_at: null,
      cumulative_input_tokens: 12400,
      cumulative_output_tokens: 3200,
      cumulative_cost_usd: 0.0123,
      ...overrides.chat
    },
    chat_available: true,
    turn_in_flight: false,
    agent_busy: false,
    has_more_older: false,
    messages: overrides.messages || [
      {
        type: "message",
        id: 9,
        role: "assistant",
        tool_name: null,
        content: { text: "Discuss aqueducts." },
        text: "Discuss aqueducts.",
        bookmarkable: true
      }
    ],
    bookmarks: [],
    recent_chats: [],
    pending_actions: [],
    agent_questions: [],
    queued_messages: [],
    attachment_groups: {
      repositories: overrides.attachment_groups?.repositories || [],
      epics: overrides.attachment_groups?.epics || [],
      jobs: overrides.attachment_groups?.jobs || [],
      documents: overrides.attachment_groups?.documents || []
    },
    documents_in_scope: [],
    attachment_results: [],
    whiteboard: {
      version: 1,
      elements: [],
      appState: {},
      files: {}
    },
    paths: {
      new_chat_path: "/chats/new",
      credentials_path: "/credentials",
      repositories_path: "/repositories",
      app_messages_path: "/api/v1/app/chats/8/messages",
      app_message_path: "/api/v1/app/chats/8/message",
      app_rename_path: "/api/v1/app/chats/8/rename",
      app_clear_path: "/api/v1/app/chats/8/messages",
      app_enqueue_message_path: "/api/v1/app/chats/8/queued_messages",
      app_stop_path: "/api/v1/app/chats/8/stop",
      app_bookmarks_path: "/api/v1/app/chats/8/bookmarks",
      app_attachments_path: "/api/v1/app/chats/8/attachments",
      app_whiteboard_path: "/api/v1/app/chats/8/whiteboard"
    }
  }
}
