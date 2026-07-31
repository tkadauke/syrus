import { jsonResponse } from "../testSupport"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import type { ReactElement } from "react"
import { MemoryRouter, Route, Routes, useLocation } from "react-router-dom"
import { beforeEach, describe, expect, it, vi } from "vitest"
import type { BootstrapPayload } from "../api/bootstrap"
import * as chatsApi from "../api/chats"
import type { ChatGroupRecord, ChatNavRecord, ChatsIndexPayload, MoreChatsPayload } from "../api/chats"
import { AppChromeV2 } from "./AppChromeV2"
import { chatSectionsFromPayload } from "./appChromeV2/helpers"

describe("AppChromeV2", () => {
  beforeEach(() => {
    window.localStorage.clear()
    delete window.syrusShell
    vi.restoreAllMocks()
  })

  it("renders the desktop sidebar with data-html2canvas-ignore to exclude it from mobile bug report screenshots", () => {
    renderAppChrome()

    const desktopSidebar = document.querySelector("aside.lg\\:flex")
    expect(desktopSidebar).not.toBeNull()
    expect(desktopSidebar).toHaveAttribute("data-html2canvas-ignore")
  })

  it("renders desktop shell notices in the sidebar above the account row", async () => {
    window.syrusShell = {
      getState: vi.fn().mockResolvedValue({
        updateReadyVersion: "0.1.3",
        claudeDetected: false,
        skillInstalled: false,
        skillOfferDismissed: false
      }),
      onStateChanged: vi.fn().mockReturnValue(() => {}),
      relaunchToUpdate: vi.fn(),
      installSkill: vi.fn().mockResolvedValue({ ok: true, message: "" }),
      dismissSkillOffer: vi.fn()
    }

    renderAppChrome()

    await screen.findByText("Relaunch to update")
    const notices = screen.getByTestId("shell-notices")
    const accountRow = screen.getByRole("navigation", { name: "Account" })
    // The notice stack sits directly above the username/account row.
    expect(notices.compareDocumentPosition(accountRow) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy()
  })

  it("shows exactly one profile link in the settings popup even when showTeamProfile is true", () => {
    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    const { unmount } = render(
      <QueryClientProvider client={queryClient}>
        <MemoryRouter initialEntries={["/repositories"]}>
          <AppChromeV2 initialBootstrap={bootstrapPayload({ team_user_count: 3 })}>
            <div />
          </AppChromeV2>
        </MemoryRouter>
      </QueryClientProvider>
    )

    fireEvent.click(screen.getByRole("button", { name: /operator@example\.com/i }))

    const profileLinks = screen.getAllByRole("link", { name: /^Profile$/i })
    expect(profileLinks).toHaveLength(1)
    expect(profileLinks[0]).toHaveAttribute("href", "/profiles/1")
    expect(screen.queryByRole("link", { name: /^My Profile$/i })).toBeNull()

    unmount()
  })

  it("hides scheduled tasks and dashboard subject links in simple mode", () => {
    renderAppChrome(<div>Dashboard</div>, {
      initialEntries: ["/dashboard"],
      bootstrap: bootstrapPayload({
        app: {
          revision: "dev",
          revision_url: null,
          version: null,
          built_at: null,
          bug_report_mode: null,
          report_issue_repo_slug: "tkadauke/syrus",
          mode: "simple",
          mode_configured: true
        }
      })
    })

    expect(screen.getByRole("link", { name: "Dashboard" })).toHaveAttribute("href", "/dashboard/epics")
    expect(screen.queryByRole("link", { name: "Schedules" })).not.toBeInTheDocument()
    expect(screen.queryByRole("link", { name: "Jobs" })).not.toBeInTheDocument()
    expect(screen.queryByRole("link", { name: "Workflows" })).not.toBeInTheDocument()
  })

  it("reuses an existing unstarted chat without creating a chat", async () => {
    const createEmptyChat = vi.spyOn(chatsApi, "createEmptyChat")
    const fetchNewChat = vi.spyOn(chatsApi, "fetchNewChat")
    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    queryClient.setQueryData(["chats", "recent"], {
      groups: [
        chatGroup({
          chats: [
            chatNav({
              id: 12,
              title: null,
              title_pending: true,
              chat_path: "/chats/12",
              current: false,
              last_message_at: null,
              created_at: "2026-06-01T00:00:00Z",
              updated_at: "2026-06-01T00:00:00Z"
            })
          ]
        })
      ],
      repositories: []
    })

    renderAppChrome(<LocationProbe />, {
      initialEntries: ["/app-shell/dashboard/jobs"],
      queryClient,
      routeWrapper: true
    })

    fireEvent.click(screen.getByRole("button", { name: "New Chat" }))

    await waitFor(() => {
      expect(screen.getByTestId("location")).toHaveTextContent("/app-shell/chats/12")
    })
    expect(createEmptyChat).not.toHaveBeenCalled()
    expect(fetchNewChat).not.toHaveBeenCalled()
  })

  it("creates an empty chat with the default repository and navigates to the returned chat path", async () => {
    vi.spyOn(chatsApi, "fetchNewChat").mockResolvedValue({ default_repository_id: 7 })
    vi.spyOn(chatsApi, "createEmptyChat").mockResolvedValue({
      message: "Chat created.",
      redirect_to: "/chats/14",
      chat: chatNav({
        id: 14,
        title: null,
        title_pending: false,
        chat_path: "/chats/14",
        last_message_at: null
      }) as chatsApi.ChatRecord
    })
    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    queryClient.setQueryData(["chats", "recent"], chatsIndexPayload())

    renderAppChrome(<LocationProbe />, {
      initialEntries: ["/app-shell/dashboard/jobs"],
      queryClient,
      routeWrapper: true
    })

    fireEvent.click(screen.getByRole("button", { name: "New Chat" }))

    await waitFor(() => {
      expect(screen.getByTestId("location")).toHaveTextContent("/app-shell/chats/14")
    })
    expect(chatsApi.fetchNewChat).toHaveBeenCalledTimes(1)
    expect(chatsApi.createEmptyChat).toHaveBeenCalledTimes(1)
    expect(chatsApi.createEmptyChat).toHaveBeenCalledWith(7)
    expect(queryClient.getQueryData<ChatsIndexPayload>(["chats", "recent"])?.groups[0].chats[0].id).toBe(14)
  })

  it("shows a notice when creating an empty chat fails", async () => {
    vi.spyOn(chatsApi, "fetchNewChat").mockResolvedValue({ default_repository_id: 7 })
    vi.spyOn(chatsApi, "createEmptyChat").mockRejectedValue(new Error("boom"))

    renderAppChrome(<LocationProbe />, {
      initialEntries: ["/app-shell/dashboard/jobs"],
      queryClient: new QueryClient({ defaultOptions: { queries: { retry: false } } }),
      routeWrapper: true
    })

    fireEvent.click(screen.getByRole("button", { name: "New Chat" }))

    expect(await screen.findByText("Unable to start chat.")).toBeInTheDocument()
    expect(screen.getByTestId("location")).toHaveTextContent("/app-shell/dashboard/jobs")
  })
})

describe("AppChromeV2 recent chats", () => {
  beforeEach(() => {
    window.localStorage.clear()
    vi.restoreAllMocks()
  })

  it("does not duplicate a main query chat when loading more chats", async () => {
    vi.spyOn(window, "fetch").mockImplementation((input) => {
      const path = String(input)
      if (path === "/api/v1/app/chats") {
        return Promise.resolve(jsonResponse(chatsIndexPayload({
          groups: [
            chatGroup({
              chats: [
                chatNav({ id: 3, title: "Newest", last_message_at: "2026-06-27T12:02:00Z" }),
                chatNav({ id: 2, title: "Main query overlap", last_message_at: "2026-06-27T12:01:00Z" })
              ],
              has_more: true
            })
          ]
        })))
      }

      if (path === "/api/v1/app/chats/more?repository_id=general&before_id=2") {
        return Promise.resolve(jsonResponse(moreChatsPayload({
          chats: [
            chatNav({ id: 2, title: "Main query overlap", last_message_at: "2026-06-27T12:01:00Z" }),
            chatNav({ id: 1, title: "Older loaded chat", last_message_at: "2026-06-27T12:00:00Z" })
          ],
          has_more: false
        })))
      }

      return Promise.resolve(jsonResponse({}))
    })

    renderAppChrome()

    fireEvent.click(await screen.findByRole("button", { name: "Show more" }))

    expect(await screen.findByText("Older loaded chat")).toBeInTheDocument()
    await waitFor(() => {
      expect(screen.getAllByText("Main query overlap")).toHaveLength(1)
    })
  })

  it("renders pinned chats before unpinned chats in the sidebar", async () => {
    vi.spyOn(window, "fetch").mockImplementation((input) => {
      if (String(input) === "/api/v1/app/chats") {
        return Promise.resolve(jsonResponse(chatsIndexPayload({
          groups: [
            chatGroup({
              chats: [
                chatNav({ id: 1, title: "Recent unpinned", pinned: false, last_message_at: "2026-06-27T12:02:00Z" }),
                chatNav({ id: 2, title: "Older pinned", pinned: true, last_message_at: "2026-06-27T12:00:00Z" })
              ]
            })
          ]
        })))
      }

      return Promise.resolve(jsonResponse({}))
    })

    renderAppChrome()

    const recentNav = await screen.findByRole("navigation", { name: "Recent chats" })
    const links = await within(recentNav).findAllByRole("link")
    expect(links.map((link) => link.textContent)).toEqual(["Older pinned", "Recent unpinned"])
    expect(within(links[0]).getByText("Older pinned").previousElementSibling?.tagName.toLowerCase()).toBe("svg")
  })

  it("shows pin and unpin actions in each chat context menu", async () => {
    vi.spyOn(window, "fetch").mockImplementation((input) => {
      if (String(input) === "/api/v1/app/chats/1" || String(input) === "/api/v1/app/chats/2") {
        return Promise.resolve(jsonResponse({ bookmarks: [] }))
      }

      return Promise.resolve(jsonResponse({}))
    })
    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    queryClient.setQueryData(["chats", "recent"], chatsIndexPayload({
      groups: [
        chatGroup({
          chats: [
            chatNav({ id: 1, title: "Unpinned chat", pinned: false }),
            chatNav({ id: 2, title: "Pinned chat", pinned: true })
          ]
        })
      ]
    }))

    renderAppChrome(undefined, { queryClient })

    fireEvent.click(await screen.findByRole("button", { name: "Chat actions for Unpinned chat" }))
    expect(await screen.findByRole("button", { name: "Pin chat" })).toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: "Chat actions for Unpinned chat" }))

    fireEvent.click(screen.getByRole("button", { name: "Chat actions for Pinned chat" }))
    expect(await screen.findByRole("button", { name: "Unpin chat" })).toBeInTheDocument()
  })

  it("pins a chat from the context menu and invalidates recent chats", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/1" && init?.method === "PATCH") {
        return Promise.resolve(jsonResponse({ message: "Chat pinned", chat: chatNav({ id: 1, title: "Unpinned chat", pinned: true }) }))
      }

      if (path === "/api/v1/app/chats/1") {
        return Promise.resolve(jsonResponse({ bookmarks: [] }))
      }

      if (path === "/api/v1/app/chats") {
        return Promise.resolve(jsonResponse(chatsIndexPayload()))
      }

      return Promise.resolve(jsonResponse({}))
    })
    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    const invalidateSpy = vi.spyOn(queryClient, "invalidateQueries")
    queryClient.setQueryData(["chats", "recent"], chatsIndexPayload({
      groups: [
        chatGroup({
          chats: [
            chatNav({ id: 1, title: "Unpinned chat", pinned: false })
          ]
        })
      ]
    }))

    renderAppChrome(undefined, { queryClient })

    fireEvent.click(await screen.findByRole("button", { name: "Chat actions for Unpinned chat" }))
    fireEvent.click(await screen.findByRole("button", { name: "Pin chat" }))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/chats/1", expect.objectContaining({
        method: "PATCH",
        body: JSON.stringify({ chat: { pinned: true } })
      }))
      expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ["chats", "recent"] })
    })
  })

  it("shows Mark as read on unread chat and Mark as unread on read chat", async () => {
    vi.spyOn(window, "fetch").mockImplementation((input) => {
      if (String(input) === "/api/v1/app/chats/1" || String(input) === "/api/v1/app/chats/2") {
        return Promise.resolve(jsonResponse({ bookmarks: [] }))
      }

      return Promise.resolve(jsonResponse({}))
    })
    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    queryClient.setQueryData(["chats", "recent"], chatsIndexPayload({
      groups: [
        chatGroup({
          chats: [
            chatNav({ id: 1, title: "Unread chat", unread: true }),
            chatNav({ id: 2, title: "Read chat", unread: false })
          ]
        })
      ]
    }))

    renderAppChrome(undefined, { queryClient })

    fireEvent.click(await screen.findByRole("button", { name: "Chat actions for Unread chat" }))
    expect(await screen.findByRole("button", { name: "Mark as read" })).toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: "Chat actions for Unread chat" }))

    fireEvent.click(screen.getByRole("button", { name: "Chat actions for Read chat" }))
    expect(await screen.findByRole("button", { name: "Mark as unread" })).toBeInTheDocument()
  })

  it("marks a chat as read from the context menu and updates the sidebar indicator", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/1/mark_read" && init?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }

      if (path === "/api/v1/app/chats/1") {
        return Promise.resolve(jsonResponse({ bookmarks: [] }))
      }

      return Promise.resolve(jsonResponse({}))
    })
    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    queryClient.setQueryData(["chats", "recent"], chatsIndexPayload({
      groups: [
        chatGroup({
          chats: [chatNav({ id: 1, title: "Unread chat", unread: true })]
        })
      ]
    }))

    renderAppChrome(undefined, { queryClient })

    fireEvent.click(await screen.findByRole("button", { name: "Chat actions for Unread chat" }))
    fireEvent.click(await screen.findByRole("button", { name: "Mark as read" }))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/chats/1/mark_read", expect.objectContaining({ method: "PATCH" }))
      const cacheData = queryClient.getQueryData<chatsApi.ChatsIndexPayload>(["chats", "recent"])
      expect(cacheData?.groups[0].chats[0].unread).toBe(false)
    })
  })

  it("marks a chat as unread from the context menu and updates the sidebar indicator", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/1/mark_unread" && init?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }

      if (path === "/api/v1/app/chats/1") {
        return Promise.resolve(jsonResponse({ bookmarks: [] }))
      }

      return Promise.resolve(jsonResponse({}))
    })
    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    queryClient.setQueryData(["chats", "recent"], chatsIndexPayload({
      groups: [
        chatGroup({
          chats: [chatNav({ id: 1, title: "Read chat", unread: false })]
        })
      ]
    }))

    renderAppChrome(undefined, { queryClient })

    fireEvent.click(await screen.findByRole("button", { name: "Chat actions for Read chat" }))
    fireEvent.click(await screen.findByRole("button", { name: "Mark as unread" }))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/chats/1/mark_unread", expect.objectContaining({ method: "PATCH" }))
      const cacheData = queryClient.getQueryData<chatsApi.ChatsIndexPayload>(["chats", "recent"])
      expect(cacheData?.groups[0].chats[0].unread).toBe(true)
    })
  })

  it("keeps Hide Chat below the pin action in the context menu", async () => {
    vi.spyOn(window, "fetch").mockImplementation((input) => {
      if (String(input) === "/api/v1/app/chats/1") {
        return Promise.resolve(jsonResponse({ bookmarks: [] }))
      }

      return Promise.resolve(jsonResponse({}))
    })
    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    queryClient.setQueryData(["chats", "recent"], chatsIndexPayload({
      groups: [
        chatGroup({
          chats: [
            chatNav({ id: 1, title: "Menu order chat", pinned: false })
          ]
        })
      ]
    }))

    renderAppChrome(undefined, { queryClient })

    fireEvent.click(await screen.findByRole("button", { name: "Chat actions for Menu order chat" }))
    const pinButton = await screen.findByRole("button", { name: "Pin chat" })
    const hideButton = screen.getByRole("button", { name: "Hide Chat" })

    expect(Boolean(pinButton.compareDocumentPosition(hideButton) & Node.DOCUMENT_POSITION_FOLLOWING)).toBe(true)
  })

  it("renames a chat from the context menu", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/1/rename" && init?.method === "PATCH") {
        return Promise.resolve(jsonResponse({ message: "Chat renamed.", chat: chatNav({ id: 1, title: "New name" }) }))
      }

      if (path === "/api/v1/app/chats/1") {
        return Promise.resolve(jsonResponse({ bookmarks: [] }))
      }

      if (path === "/api/v1/app/chats") {
        return Promise.resolve(jsonResponse(chatsIndexPayload()))
      }

      return Promise.resolve(jsonResponse({}))
    })
    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    const invalidateSpy = vi.spyOn(queryClient, "invalidateQueries")
    queryClient.setQueryData(["chats", "recent"], chatsIndexPayload({
      groups: [
        chatGroup({
          chats: [
            chatNav({ id: 1, title: "Old name" })
          ]
        })
      ]
    }))

    renderAppChrome(undefined, { queryClient })

    fireEvent.click(await screen.findByRole("button", { name: "Chat actions for Old name" }))
    fireEvent.click(await screen.findByRole("button", { name: "Rename" }))

    const input = await screen.findByLabelText("Chat name")
    expect(input).toHaveValue("Old name")

    // The dialog must portal OUT of the row's `absolute … -translate-y-1/2`
    // actions wrapper: a CSS transform turns that ancestor into the containing
    // block for fixed-position descendants, clipping the overlay to the row.
    const renameDialog = screen.getByRole("dialog")
    expect(renameDialog.closest('[class*="-translate-y-1/2"]')).toBeNull()
    expect(renameDialog.parentElement?.parentElement).toBe(document.body)
    fireEvent.change(input, { target: { value: "New name" } })
    fireEvent.click(screen.getByRole("button", { name: "Save" }))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/chats/1/rename", expect.objectContaining({
        method: "PATCH",
        body: JSON.stringify({ chat: { title: "New name" } })
      }))
      expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ["chats", "recent"] })
    })
  })

  it("deletes a chat from the context menu after confirmation", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/1" && init?.method === "DELETE") {
        return Promise.resolve(jsonResponse({ message: "Chat deleted." }))
      }

      if (path === "/api/v1/app/chats/1") {
        return Promise.resolve(jsonResponse({ bookmarks: [] }))
      }

      if (path === "/api/v1/app/chats") {
        return Promise.resolve(jsonResponse(chatsIndexPayload()))
      }

      return Promise.resolve(jsonResponse({}))
    })
    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    queryClient.setQueryData(["chats", "recent"], chatsIndexPayload({
      groups: [
        chatGroup({
          chats: [
            chatNav({ id: 1, title: "Doomed chat" })
          ]
        })
      ]
    }))

    renderAppChrome(undefined, { queryClient })

    fireEvent.click(await screen.findByRole("button", { name: "Chat actions for Doomed chat" }))
    fireEvent.click(await screen.findByRole("button", { name: "Delete Chat" }))

    expect(await screen.findByText("This permanently deletes the chat, its messages, and all associated data. This cannot be undone.")).toBeInTheDocument()

    // Portaled to document.body, not nested in the transformed row wrapper
    // (which would clip/misposition the fixed overlay).
    const deleteDialog = screen.getByRole("dialog")
    expect(deleteDialog.closest('[class*="-translate-y-1/2"]')).toBeNull()
    expect(deleteDialog.parentElement?.parentElement).toBe(document.body)

    fireEvent.click(screen.getByRole("button", { name: "Delete" }))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/chats/1", expect.objectContaining({ method: "DELETE" }))
    })
    await waitFor(() => {
      expect(screen.queryByText("Doomed chat")).not.toBeInTheDocument()
    })
  })

  it("surfaces the server error when chat deletion is refused", async () => {
    vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/1" && init?.method === "DELETE") {
        return Promise.resolve(new Response(JSON.stringify({
          error: { code: "turn_in_flight", message: "Cannot delete this chat while a turn is in progress. Stop the turn first." }
        }), { status: 409, headers: { "Content-Type": "application/json" } }))
      }

      if (path === "/api/v1/app/chats/1") {
        return Promise.resolve(jsonResponse({ bookmarks: [] }))
      }

      if (path === "/api/v1/app/chats") {
        return Promise.resolve(jsonResponse(chatsIndexPayload()))
      }

      return Promise.resolve(jsonResponse({}))
    })
    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    queryClient.setQueryData(["chats", "recent"], chatsIndexPayload({
      groups: [
        chatGroup({
          chats: [
            chatNav({ id: 1, title: "Busy chat" })
          ]
        })
      ]
    }))

    renderAppChrome(undefined, { queryClient })

    fireEvent.click(await screen.findByRole("button", { name: "Chat actions for Busy chat" }))
    fireEvent.click(await screen.findByRole("button", { name: "Delete Chat" }))
    fireEvent.click(await screen.findByRole("button", { name: "Delete" }))

    expect(await screen.findByText("Cannot delete this chat while a turn is in progress. Stop the turn first.")).toBeInTheDocument()
  })
})

describe("SidebarSearchForm", () => {
  beforeEach(() => {
    window.localStorage.clear()
    vi.restoreAllMocks()
  })

  it("populates the search field from the URL when on the search page", () => {
    renderAppChrome(<div />, {
      initialEntries: ["/app-shell/search?q=hello%20world"]
    })

    expect(screen.getByLabelText("Search Syrus")).toHaveValue("hello world")
  })

  it("does not populate the search field with the dashboard filter param", () => {
    renderAppChrome(<div />, {
      initialEntries: ["/app-shell/dashboard/jobs?q=eyJhbmQiOlt7ImZwZWNlIjpOYXhUZU1"]
    })

    expect(screen.getByLabelText("Search Syrus")).toHaveValue("")
  })
})

describe("chat row mode icons", () => {
  beforeEach(() => {
    window.localStorage.clear()
    vi.restoreAllMocks()
  })

  it("shows planning icon by default when chat has no mode set", async () => {
    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    queryClient.setQueryData(["chats", "recent"], chatsIndexPayload({
      groups: [chatGroup({ chats: [chatNav({ id: 1, title: "Planning chat" })] })]
    }))

    renderAppChrome(undefined, { queryClient })

    await screen.findByText("Planning chat")
    expect(screen.getByTestId("mode-icon-planning")).toBeInTheDocument()
  })

  it("shows coding icon when coding_mode feature is enabled and chat mode is coding", async () => {
    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    queryClient.setQueryData(["chats", "recent"], chatsIndexPayload({
      groups: [chatGroup({ chats: [chatNav({ id: 1, title: "Coding chat", mode: "coding" })] })]
    }))

    renderAppChrome(undefined, {
      queryClient,
      bootstrap: bootstrapPayload({ feature_flags: { coding_mode: true } })
    })

    await screen.findByText("Coding chat")
    expect(screen.getByTestId("mode-icon-coding")).toBeInTheDocument()
    expect(screen.queryByTestId("mode-icon-planning")).not.toBeInTheDocument()
  })

  it("falls back to planning icon when coding_mode flag is disabled even if chat mode is coding", async () => {
    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    queryClient.setQueryData(["chats", "recent"], chatsIndexPayload({
      groups: [chatGroup({ chats: [chatNav({ id: 1, title: "Coding chat", mode: "coding" })] })]
    }))

    renderAppChrome(undefined, {
      queryClient,
      bootstrap: bootstrapPayload({ feature_flags: {} })
    })

    await screen.findByText("Coding chat")
    expect(screen.getByTestId("mode-icon-planning")).toBeInTheDocument()
    expect(screen.queryByTestId("mode-icon-coding")).not.toBeInTheDocument()
  })

  it("shows local icon when local_mode feature is enabled and chat mode is local", async () => {
    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    queryClient.setQueryData(["chats", "recent"], chatsIndexPayload({
      groups: [chatGroup({ chats: [chatNav({ id: 1, title: "Local chat", mode: "local" })] })]
    }))

    renderAppChrome(undefined, {
      queryClient,
      bootstrap: bootstrapPayload({ feature_flags: { local_mode: true } })
    })

    await screen.findByText("Local chat")
    expect(screen.getByTestId("mode-icon-local")).toBeInTheDocument()
    expect(screen.queryByTestId("mode-icon-planning")).not.toBeInTheDocument()
  })

  it("falls back to planning icon when local_mode flag is disabled even if chat mode is local", async () => {
    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    queryClient.setQueryData(["chats", "recent"], chatsIndexPayload({
      groups: [chatGroup({ chats: [chatNav({ id: 1, title: "Local chat", mode: "local" })] })]
    }))

    renderAppChrome(undefined, {
      queryClient,
      bootstrap: bootstrapPayload({ feature_flags: {} })
    })

    await screen.findByText("Local chat")
    expect(screen.getByTestId("mode-icon-planning")).toBeInTheDocument()
    expect(screen.queryByTestId("mode-icon-local")).not.toBeInTheDocument()
  })

  it("wraps status dots in a group-hover:hidden container so they hide when the action menu appears", async () => {
    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    queryClient.setQueryData(["chats", "recent"], chatsIndexPayload({
      groups: [chatGroup({ chats: [chatNav({ id: 1, title: "Active chat", turn_in_flight: true })] })]
    }))

    renderAppChrome(undefined, { queryClient })

    await screen.findByText("Active chat")
    const activityMarker = screen.getByTitle("Chat turn active")
    expect(activityMarker.parentElement?.className).toContain("group-hover:hidden")
  })
})

describe("chatSectionsFromPayload", () => {
  it("deduplicates loaded chats that overlap with main query groups", () => {
    const sections = chatSectionsFromPayload(
      [
        chatGroup({
          key: "general",
          chats: [
            chatNav({ id: 2, title: "Main query overlap", last_message_at: "2026-06-27T12:01:00Z" }),
            chatNav({ id: 1, title: "Main only", last_message_at: "2026-06-27T12:00:00Z" })
          ],
          has_more: true
        })
      ],
      {
        general: {
          chats: [
            chatNav({ id: 2, title: "Main query overlap", last_message_at: "2026-06-27T12:01:00Z" }),
            chatNav({ id: 3, title: "Loaded only", last_message_at: "2026-06-27T12:02:00Z" })
          ],
          has_more: false
        }
      }
    )

    expect(sections[0].chats.map((chat) => chat.id)).toEqual([3, 2, 1])
    expect(sections[0].chats.filter((chat) => chat.id === 2)).toHaveLength(1)
    expect(sections[0].has_more).toBe(false)
  })
})

function renderAppChrome(
  ui: ReactElement = <div>Dashboard</div>,
  options: {
    initialEntries?: string[]
    queryClient?: QueryClient
    routeWrapper?: boolean
    bootstrap?: BootstrapPayload
  } = {}
) {
  const queryClient = options.queryClient ?? new QueryClient({ defaultOptions: { queries: { retry: false } } })
  const chrome = (
    <AppChromeV2 initialBootstrap={options.bootstrap ?? bootstrapPayload()}>
      {ui}
    </AppChromeV2>
  )

  return render(
    <QueryClientProvider client={queryClient}>
      <MemoryRouter initialEntries={options.initialEntries ?? ["/repositories"]}>
        {options.routeWrapper ? (
          <Routes>
            <Route element={chrome} path="*" />
          </Routes>
        ) : chrome}
      </MemoryRouter>
    </QueryClientProvider>
  )
}

function LocationProbe() {
  const location = useLocation()
  return <div data-testid="location">{location.pathname}</div>
}

function chatNav(overrides: Partial<ChatNavRecord> = {}): ChatNavRecord {
  return {
    id: 1,
    title: "Chat",
    title_pending: false,
    pinned: false,
    pinned_context: null,
    chat_provider: "claude",
    chat_path: `/chats/${overrides.id ?? 1}`,
    repository: null,
    stop_requested_at: null,
    cumulative_input_tokens: 0,
    cumulative_output_tokens: 0,
    cumulative_cost_usd: 0,
    pending_proposal_count: 0,
    scratchpad_items_count: 0,
    current: false,
    last_message_at: "2026-06-27T12:00:00Z",
    unread: false,
    created_at: "2026-06-27T12:00:00Z",
    updated_at: "2026-06-27T12:00:00Z",
    ...overrides
  }
}

function chatGroup(overrides: Partial<ChatGroupRecord> = {}): ChatGroupRecord {
  return {
    key: "general",
    label: "General",
    repository_id: null,
    chats: [],
    has_more: false,
    ...overrides
  }
}

function chatsIndexPayload(overrides: Partial<ChatsIndexPayload> = {}): ChatsIndexPayload {
  return {
    groups: [],
    repositories: [],
    ...overrides
  }
}

function moreChatsPayload(overrides: Partial<MoreChatsPayload> = {}): MoreChatsPayload {
  return {
    chats: [],
    has_more: false,
    ...overrides
  }
}

function bootstrapPayload(overrides: Partial<BootstrapPayload> = {}): BootstrapPayload {
  return {
    current_user: {
      id: 1,
      email_address: "operator@example.com",
      name: "Operator",
      first_name: null,
      last_name: null,
      display_name: "Operator",
      admin: true,
      scheduling_paused: false,
      landing_paused: false,
      agent_provider: "claude",
      agent_max_turns: 200,
      theme: "light"
    },
    team_user_count: 1,
    app: { revision: "dev", revision_url: null },
    public: {
      first_signup: false,
      signups_open: false,
      signup_path: "/users/new",
      sign_in_path: "/session/new",
      docs_url: "https://syrus.dev/docs/getting-started",
      evaluation_url: "https://syrus.dev/docs/deployment/docker-compose"
    },
    navigation: { default_chat_path: "/dashboard" },
    setup: {
      complete: true,
      chat_started: true,
      next_step: "complete",
      progress: {
        completed: 4,
        total: 4,
        steps: []
      }
    },
    setup_status: null,
    csrf_token: "csrf-token",
    unread_notifications_count: 0,
    feature_flags: {},
    ...overrides
  } as unknown as BootstrapPayload
}
