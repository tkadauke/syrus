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

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } })
}

function chatPayload(overrides: { messages?: Array<Record<string, unknown>> } = {}) {
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
      cumulative_cost_usd: 0.0123
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
      repositories: [],
      epics: [],
      jobs: [],
      documents: []
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
