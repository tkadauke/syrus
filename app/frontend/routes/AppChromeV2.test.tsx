import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import type { ReactElement } from "react"
import { MemoryRouter, Route, Routes, useLocation } from "react-router-dom"
import { beforeEach, describe, expect, it, vi } from "vitest"
import type { BootstrapPayload } from "../api/bootstrap"
import * as chatsApi from "../api/chats"
import type { ChatGroupRecord, ChatNavRecord, ChatsIndexPayload, MoreChatsPayload } from "../api/chats"
import { AppChromeV2, chatSectionsFromPayload } from "./AppChromeV2"

describe("AppChromeV2", () => {
  beforeEach(() => {
    window.localStorage.clear()
    vi.restoreAllMocks()
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
  } = {}
) {
  const queryClient = options.queryClient ?? new QueryClient({ defaultOptions: { queries: { retry: false } } })
  const chrome = (
    <AppChromeV2 initialBootstrap={bootstrapPayload()}>
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
    chat_path: `/chats/${overrides.id ?? 1}`,
    repository: null,
    stop_requested_at: null,
    cumulative_input_tokens: 0,
    cumulative_output_tokens: 0,
    cumulative_cost_usd: 0,
    pending_proposal_count: 0,
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

function jsonResponse(body: unknown) {
  return new Response(JSON.stringify(body), {
    headers: { "Content-Type": "application/json" }
  })
}
