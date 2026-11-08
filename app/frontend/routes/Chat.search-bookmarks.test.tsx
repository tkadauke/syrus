import { jsonResponse } from "../testSupport"
import { act, fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { describe, expect, it, vi } from "vitest"
import { MemoryRouter } from "react-router-dom"
import { App } from "./App"
import { bootstrapPayload } from "../test/app/bootstrap"
import { chatPayload, chatSearchMatch, chatSearchPayload, sidebarChat, sidebarGroups } from "../test/app/chatPayloads"
import { installAppTestLifecycle } from "../test/app/lifecycle"

vi.mock("@rails/actioncable", async () => (await import("../test/app/appMocks")).actionCableModule())
vi.mock("@excalidraw/excalidraw", async () => (await import("../test/app/appMocks")).excalidrawModule())
vi.mock("html2canvas-pro", async () => (await import("../test/app/appMocks")).html2canvasModule())

describe("App chat search and bookmarks", () => {
  installAppTestLifecycle()

  it("renders the v2 chat search empty state and all filter fields", async () => {
    const script = document.createElement("script")
    script.id = "syrus-bootstrap-data"
    script.type = "application/json"
    script.textContent = JSON.stringify(
      bootstrapPayload({
        current_user: {
          ...bootstrapPayload().current_user
        },
        feature_flags: {
          v2_ui: true
        }
      })
    )
    document.body.appendChild(script)
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input) => {
      const path = String(input)
      if (path === "/api/v1/app/chats") {
        return Promise.resolve(new Response(JSON.stringify({ groups: [], repositories: [] }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path.includes("field=repository_id")) {
        return Promise.resolve(
          new Response(JSON.stringify({ options: [{ value: "3", label: "acme/widgets" }] }), { status: 200, headers: { "Content-Type": "application/json" } })
        )
      }
      if (path.includes("field=epic_id")) {
        return Promise.resolve(
          new Response(JSON.stringify({ options: [{ value: "5", label: "EPIC-5 Search" }] }), { status: 200, headers: { "Content-Type": "application/json" } })
        )
      }
      if (path.includes("field=job_id")) {
        return Promise.resolve(
          new Response(JSON.stringify({ options: [{ value: "8", label: "JOB-8 Recent job" }] }), {
            status: 200,
            headers: { "Content-Type": "application/json" }
          })
        )
      }

      return Promise.resolve(new Response(JSON.stringify({}), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/chats/search"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      expect(await screen.findByText("Search your chats or filter by repository, epic, or job.")).toBeInTheDocument()
      fireEvent.click(screen.getByRole("button", { name: "+ Add filter" }))
      expect(screen.getByRole("button", { name: "Search text" })).toBeInTheDocument()
      expect(screen.getByRole("button", { name: "Repository select" })).toBeInTheDocument()
      expect(screen.getByRole("button", { name: "Epic select" })).toBeInTheDocument()
      expect(screen.getByRole("button", { name: "Job select" })).toBeInTheDocument()
    } finally {
      fetchSpy.mockRestore()
      script.remove()
    }
  })

  it("renders v2 chat search result cards, expands matches, and follows message links", async () => {
    // Freeze Date so the fixture's created_at ("2026-06-20") stays in the
    // "5 days ago" range and Intl.RelativeTimeFormat produces "X days ago",
    // not "last month" (which happens once the gap crosses 30 days).
    vi.useFakeTimers({ toFake: ["Date"] })
    vi.setSystemTime(new Date("2026-06-25T12:00:00Z"))
    const script = document.createElement("script")
    script.id = "syrus-bootstrap-data"
    script.type = "application/json"
    script.textContent = JSON.stringify(
      bootstrapPayload({
        current_user: {
          ...bootstrapPayload().current_user
        },
        feature_flags: {
          v2_ui: true
        }
      })
    )
    document.body.appendChild(script)
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input) => {
      const path = String(input)
      if (path === "/api/v1/app/chats") {
        return Promise.resolve(new Response(JSON.stringify({ groups: [], repositories: [] }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path.startsWith("/api/v1/app/filters/fk_options")) {
        return Promise.resolve(new Response(JSON.stringify({ options: [] }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/filters/schema?subject=chat_message") {
        return Promise.resolve(new Response(JSON.stringify({ fields: [] }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/chats/search?q=needle") {
        return Promise.resolve(new Response(JSON.stringify(chatSearchPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/chats/search/messages?q=needle&chat_session_id=77") {
        return Promise.resolve(
          new Response(
            JSON.stringify({
              matches: [
                chatSearchMatch({ message_id: 11, role: "assistant", snippet: "First <b>needle</b>" }),
                chatSearchMatch({ message_id: 12, role: "user", snippet: "Second <b>needle</b>" }),
                chatSearchMatch({ message_id: 13, role: "assistant", snippet: "Third <b>needle</b>" }),
                chatSearchMatch({ message_id: 14, role: "tool_result", snippet: "Fourth <b>needle</b>" })
              ]
            }),
            { status: 200, headers: { "Content-Type": "application/json" } }
          )
        )
      }
      if (path === "/api/v1/app/chats/77") {
        return Promise.resolve(new Response(JSON.stringify(chatPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.resolve(new Response(JSON.stringify({}), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/chats/search?q=needle"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      expect(await screen.findByRole("link", { name: "Forum planning" })).toHaveAttribute("href", "/chats/77")
      expect(screen.getByText("Ada")).toBeInTheDocument()
      expect(screen.getByText((_content, element) => element?.textContent === "Best needle ignored")).toBeInTheDocument()
      expect(screen.getByText(/ago$/)).toBeInTheDocument()

      fireEvent.click(screen.getByRole("button", { name: "Show 1 more match" }))
      const secondMatch = await screen.findByText((_content, element) => element?.textContent === "Second needle")
      fireEvent.click(secondMatch.closest("button") as HTMLButtonElement)

      await waitFor(() => {
        expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/chats/77", expect.objectContaining({ credentials: "same-origin" }))
      })
    } finally {
      vi.useRealTimers()
      fetchSpy.mockRestore()
      script.remove()
    }
  })

  it("renders active chat bookmarks from the v2 sidebar cache", async () => {
    const scrollIntoView = vi.fn()
    Object.defineProperty(window.HTMLElement.prototype, "scrollIntoView", { configurable: true, value: scrollIntoView })
    const script = document.createElement("script")
    script.id = "syrus-bootstrap-data"
    script.type = "application/json"
    script.textContent = JSON.stringify(
      bootstrapPayload({
        current_user: {
          ...bootstrapPayload().current_user
        },
        feature_flags: {
          v2_ui: true
        }
      })
    )
    document.body.appendChild(script)
    const initialPayload = chatPayload({ hasMoreOlder: true })
    initialPayload.bookmarks = [{ id: 7, label: "Earlier aqueduct note", chat_message_id: 4, anchor_message_id: 5 }]
    const recentChats = [
      sidebarChat({
        id: 8,
        title: "Aqueduct planning",
        repository: { id: 3, slug: "acme/widgets", repository_path: "/repositories/3" },
        last_message_at: "2026-06-18T12:00:00Z"
      })
    ]
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats") {
        return Promise.resolve(
          new Response(JSON.stringify({ groups: sidebarGroups(recentChats), repositories: [] }), {
            status: 200,
            headers: { "Content-Type": "application/json" }
          })
        )
      }
      if (path === "/api/v1/app/chats/8/mark_read" && init?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }
      if (path === "/api/v1/app/chats/8/messages?before=9") {
        return Promise.resolve(
          new Response(
            JSON.stringify({
              has_more_older: false,
              messages: [
                {
                  type: "message",
                  id: 5,
                  role: "assistant",
                  text: "Earlier **aqueduct** note.",
                  bookmarkable: true
                }
              ]
            }),
            { status: 200, headers: { "Content-Type": "application/json" } }
          )
        )
      }
      if (path === "/api/v1/app/chats/8/bookmarks") {
        return Promise.resolve(jsonResponse({ bookmarks: initialPayload.bookmarks }))
      }

      return Promise.resolve(new Response(JSON.stringify(initialPayload), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      expect(await screen.findByText("Discuss aqueducts.")).toBeInTheDocument()
      fireEvent.click(await screen.findByRole("button", { name: "Chat actions for Aqueduct planning" }))
      expect(await screen.findByText("Bookmarks")).toHaveClass("font-semibold")
      const bookmark = await screen.findByRole("link", { name: "Earlier aqueduct note" })
      expect(bookmark).toHaveAttribute("href", "#message-5")
      fireEvent.click(bookmark)
      expect(screen.queryByRole("link", { name: "Earlier aqueduct note" })).not.toBeInTheDocument()
      expect(scrollIntoView).not.toHaveBeenCalled()
      expect(fetchSpy).not.toHaveBeenCalledWith("/api/v1/app/chats/8/messages?before=9", expect.anything())
    } finally {
      fetchSpy.mockRestore()
      script.remove()
    }
  })

  it("renders inactive chat bookmarks from the v2 sidebar cache with chat deep links", async () => {
    const script = document.createElement("script")
    script.id = "syrus-bootstrap-data"
    script.type = "application/json"
    script.textContent = JSON.stringify(
      bootstrapPayload({
        current_user: {
          ...bootstrapPayload().current_user
        },
        feature_flags: {
          v2_ui: true
        }
      })
    )
    document.body.appendChild(script)
    const inactivePayload = chatPayload({ id: 11, chatPath: "/chats/11" })
    inactivePayload.bookmarks = [{ id: 12, label: "Inactive aqueduct note", chat_message_id: 13, anchor_message_id: 13 }]
    const recentChats = [
      sidebarChat({
        id: 8,
        title: "Aqueduct planning",
        repository: { id: 3, slug: "acme/widgets", repository_path: "/repositories/3" },
        last_message_at: "2026-06-18T12:00:00Z"
      }),
      sidebarChat({
        id: 11,
        title: "Canal follow-up",
        repository: { id: 3, slug: "acme/widgets", repository_path: "/repositories/3" },
        last_message_at: "2026-06-17T12:00:00Z"
      })
    ]
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input) => {
      const path = String(input)
      if (path === "/api/v1/app/chats") {
        return Promise.resolve(
          new Response(JSON.stringify({ groups: sidebarGroups(recentChats), repositories: [] }), {
            status: 200,
            headers: { "Content-Type": "application/json" }
          })
        )
      }

      return Promise.resolve(new Response(JSON.stringify(chatPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
    })
    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    queryClient.setQueryData(["chat-bookmarks", "11", ""], { bookmarks: inactivePayload.bookmarks })

    try {
      render(
        <QueryClientProvider client={queryClient}>
          <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      const recentNav = await screen.findByRole("navigation", { name: "Recent chats" })
      // The dropdown renders through a FloatingPortal outside `recentNav`; query
      // its content on `screen`.
      fireEvent.click(await within(recentNav).findByRole("button", { name: "Chat actions for Canal follow-up" }))
      expect(await screen.findByText("Bookmarks")).toHaveClass("font-semibold")
      expect(screen.queryByText("No bookmarks yet")).not.toBeInTheDocument()
      expect(screen.getByRole("link", { name: "Inactive aqueduct note" })).toHaveAttribute("href", "/app-shell/chats/11#message-13")
    } finally {
      fetchSpy.mockRestore()
      script.remove()
    }
  })

  it("fetches inactive chat bookmarks from the v2 sidebar menu when uncached", async () => {
    const script = document.createElement("script")
    script.id = "syrus-bootstrap-data"
    script.type = "application/json"
    script.textContent = JSON.stringify(
      bootstrapPayload({
        current_user: {
          ...bootstrapPayload().current_user
        },
        feature_flags: {
          v2_ui: true
        }
      })
    )
    document.body.appendChild(script)
    const inactivePayload = chatPayload({ id: 11, chatPath: "/chats/11" })
    inactivePayload.bookmarks = [{ id: 12, label: "Inactive aqueduct note", chat_message_id: 13, anchor_message_id: 13 }]
    const recentChats = [
      sidebarChat({
        id: 8,
        title: "Aqueduct planning",
        repository: { id: 3, slug: "acme/widgets", repository_path: "/repositories/3" },
        last_message_at: "2026-06-18T12:00:00Z"
      }),
      sidebarChat({
        id: 11,
        title: "Canal follow-up",
        repository: { id: 3, slug: "acme/widgets", repository_path: "/repositories/3" },
        last_message_at: "2026-06-17T12:00:00Z"
      })
    ]
    let resolveInactiveChat: (response: Response) => void = () => undefined
    const inactiveChatRequest = new Promise<Response>((resolve) => {
      resolveInactiveChat = resolve
    })
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats") {
        return Promise.resolve(
          new Response(JSON.stringify({ groups: sidebarGroups(recentChats), repositories: [] }), {
            status: 200,
            headers: { "Content-Type": "application/json" }
          })
        )
      }
      if (path === "/api/v1/app/chats/8/mark_read" && init?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }
      if (path === "/api/v1/app/chats/11/bookmarks") {
        return inactiveChatRequest
      }

      return Promise.resolve(new Response(JSON.stringify(chatPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      const recentNav = await screen.findByRole("navigation", { name: "Recent chats" })
      // The dropdown renders through a FloatingPortal outside `recentNav`; query
      // its content on `screen`.
      fireEvent.click(await within(recentNav).findByRole("button", { name: "Chat actions for Canal follow-up" }))
      expect(screen.getByText("Loading bookmarks...")).toBeInTheDocument()

      await act(async () => {
        resolveInactiveChat(jsonResponse({ bookmarks: inactivePayload.bookmarks }))
        await inactiveChatRequest
      })

      expect(await screen.findByRole("link", { name: "Inactive aqueduct note" })).toHaveAttribute("href", "/app-shell/chats/11#message-13")
      expect(screen.queryByText("Loading bookmarks...")).not.toBeInTheDocument()
      expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/chats/11/bookmarks", expect.objectContaining({ credentials: "same-origin" }))
    } finally {
      fetchSpy.mockRestore()
      script.remove()
    }
  })
})
