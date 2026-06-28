import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import type { ReactElement } from "react"
import { MemoryRouter, Route, Routes, useLocation } from "react-router-dom"
import { beforeEach, describe, expect, it, vi } from "vitest"
import type { BootstrapPayload } from "../api/bootstrap"
import type { ChatGroupRecord, ChatNavRecord, ChatsIndexPayload, MoreChatsPayload } from "../api/chats"
import { AppChromeV2, chatSectionsFromPayload } from "./AppChromeV2"

describe("AppChromeV2", () => {
  beforeEach(() => {
    window.localStorage.clear()
    vi.restoreAllMocks()
  })

  it("navigates to the new chat route without creating a chat", async () => {
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
  })

  it("does nothing when already on the new chat route", () => {
    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    queryClient.setQueryData(["chats", "recent"], chatsIndexPayload())

    renderAppChrome(<LocationProbe />, {
      initialEntries: ["/app-shell/chats/new"],
      queryClient,
      routeWrapper: true
    })

    fireEvent.click(screen.getByRole("button", { name: "New Chat" }))

    expect(screen.getByTestId("location")).toHaveTextContent("/app-shell/chats/new")
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
    navigation: { default_chat_path: "/chats/new" },
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
