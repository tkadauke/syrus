import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { act, fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import { MemoryRouter, useLocation } from "react-router-dom"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import type { ChatBookmark, ChatGoal, ChatGroupRecord, ChatNavRecord, ChatPayload, ChatsIndexPayload } from "../../api/chats"
import { jsonResponse } from "../../testSupport"
import { RecentChatsSidebar } from "./RecentChatsSidebar"

const SIDEBAR_SETTINGS_KEY = "syrus.recent_chats_sidebar.settings"

function LocationProbe() {
  const location = useLocation()
  return <div data-testid="location">{location.pathname}</div>
}

function renderSidebar(
  chats: ChatNavRecord[],
  options: { availableChatTypes?: ChatsIndexPayload["available_chat_types"]; featureFlags?: Record<string, boolean>; groups?: ChatGroupRecord[]; onCloseDrawer?: () => void; onStartChat?: (repositoryId?: number | null) => void; prefix?: string; renderOptions?: Parameters<typeof render>[1] } = {}
) {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  queryClient.setQueryData<ChatsIndexPayload>(["chats", "recent"], chatsIndexPayload({
    available_chat_types: options.availableChatTypes,
    groups: options.groups ?? [chatGroup({ chats })]
  }))

  return render(
    <QueryClientProvider client={queryClient}>
      <MemoryRouter initialEntries={["/"]}>
        <RecentChatsSidebar
          featureFlags={options.featureFlags ?? {}}
          onCloseDrawer={options.onCloseDrawer ?? (() => {})}
          onNotice={() => {}}
          onStartChat={options.onStartChat}
          prefix={options.prefix ?? ""}
          userPresent
        />
        <LocationProbe />
      </MemoryRouter>
    </QueryClientProvider>,
    options.renderOptions
  )
}

function withMatchMedia(matches: boolean) {
  const original = Object.getOwnPropertyDescriptor(window, "matchMedia")
  Object.defineProperty(window, "matchMedia", {
    configurable: true,
    value: vi.fn().mockImplementation((query: string) => ({
      matches,
      media: query,
      onchange: null,
      addEventListener: vi.fn(),
      removeEventListener: vi.fn(),
      addListener: vi.fn(),
      removeListener: vi.fn(),
      dispatchEvent: vi.fn()
    }))
  })

  return () => {
    if (original) Object.defineProperty(window, "matchMedia", original)
    else Reflect.deleteProperty(window, "matchMedia")
  }
}

describe("RecentChatsSidebar active chat highlighting", () => {
  it("shows a red usage-limit warning for affected chats", () => {
    renderSidebar([
      chatNav({
        id: 1,
        title: "Codex chat",
        provider_availability: {
          provider: "codex",
          label: "Codex",
          model: null,
          state: "exhausted",
          open: true,
          usage_exhausted: true,
          retry_after: null,
          reason: "Provider usage limit exhausted.",
          message: "Codex usage limit reached. This item uses Codex until usage resets."
        }
      })
    ])

    expect(screen.getByRole("img", { name: /Codex usage limit reached/ })).toBeInTheDocument()
  })

  it("includes provider evidence details in usage warning labels", () => {
    renderSidebar([
      chatNav({
        id: 1,
        title: "Codex chat",
        provider_availability: {
          provider: "codex",
          label: "Codex",
          model: "gpt-5.5",
          state: "exhausted",
          open: true,
          usage_exhausted: true,
          retry_after: null,
          reason: "Provider usage limit exhausted.",
          message: "Codex usage limit reached for gpt-5.5.",
          evidence: {
            current: {
              status: "exhausted",
              source: "usage_probe",
              observed_at: "2026-08-04T16:00:00Z",
              provider: "codex",
              account_id: "account-123",
              model: "gpt-5.5",
              http_status: 200
            }
          }
        }
      })
    ])

    const warning = screen.getByRole("img", { name: /Evidence: exhausted from usage_probe/ })
    expect(warning).toHaveAttribute("title", expect.stringContaining("scope codex / account account-123 / model gpt-5.5"))
    expect(warning).toHaveAttribute("title", expect.stringContaining("HTTP 200"))
  })

  it("does not highlight a chat as active when the URL is not /chats/:id even if current=true", () => {
    renderSidebar([chatNav({ id: 1, title: "My Chat", current: true })])

    const link = screen.getByRole("link", { name: "My Chat" })
    expect(link).not.toHaveClass("bg-brand/10")
    expect(link.className).not.toMatch(/\b(?:bg|text)-blue-\d{2,3}\b/)
  })

  it("truncates recent chat titles and exposes the full title as a tooltip", () => {
    const title = "Coding: Fix split review diff panes to divide the viewport evenly across a long recent-chat row"
    renderSidebar([chatNav({ id: 1, title })])

    const link = screen.getByRole("link", { name: title })
    expect(link).toHaveAttribute("title", title)
    expect(within(link).getByText(title)).toHaveClass("truncate")
  })

  it("highlights a chat as active when the URL matches /chats/:id", () => {
    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    queryClient.setQueryData<ChatsIndexPayload>(["chats", "recent"], chatsIndexPayload({
      groups: [chatGroup({ chats: [chatNav({ id: 42, title: "Active Chat", chat_path: "/chats/42" })] })]
    }))

    render(
      <QueryClientProvider client={queryClient}>
        <MemoryRouter initialEntries={["/chats/42"]}>
          <RecentChatsSidebar
            featureFlags={{}}
            onCloseDrawer={() => {}}
            onNotice={() => {}}
            prefix=""
            userPresent
          />
        </MemoryRouter>
      </QueryClientProvider>
    )

    const link = screen.getByRole("link", { name: "Active Chat" })
    expect(link).toHaveClass("bg-brand/10", "text-brand")
    expect(link.className).not.toMatch(/\b(?:bg|text)-blue-\d{2,3}\b/)
  })
})

describe("RecentChatsSidebar repository quick-start", () => {
  it("starts a new chat attached to the repository group", () => {
    const startChat = vi.fn()
    renderSidebar([], {
      groups: [
        chatGroup({
          key: "repository-7",
          label: "acme/widgets",
          repository_id: 7,
          group_by: "repository",
          group_value: "7",
          chats: [chatNav({ id: 1, title: "Repo chat" })]
        })
      ],
      onStartChat: startChat
    })

    fireEvent.click(screen.getByRole("button", { name: "New chat in acme/widgets" }))

    expect(startChat).toHaveBeenCalledWith(7)
  })

  it("starts a repositoryless chat from the General repository group", () => {
    const startChat = vi.fn()
    renderSidebar([], {
      groups: [
        chatGroup({
          key: "general",
          label: "General",
          repository_id: null,
          group_by: "repository",
          group_value: null,
          chats: [chatNav({ id: 1, title: "General chat" })]
        })
      ],
      onStartChat: startChat
    })

    const settingsButton = screen.getByRole("button", { name: "Recent chats settings" })
    const generalQuickStart = screen.getByRole("button", { name: "New chat in General" })
    fireEvent.click(generalQuickStart)

    expect(startChat).toHaveBeenCalledWith(null)
    expect(generalQuickStart).toHaveClass("h-6", "w-6", "p-0")
    expect(settingsButton).toHaveClass("h-6", "w-6", "p-0")
  })
})

describe("RecentChatsSidebar settings", () => {
  afterEach(() => {
    window.localStorage.clear()
    vi.restoreAllMocks()
    vi.unstubAllGlobals()
  })

  it("refetches with selected settings and uses the same page size for show more", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input) => {
      const path = String(input)
      if (path.startsWith("/api/v1/app/chats/more")) {
        return Promise.resolve(jsonResponse({ chats: [], has_more: false }))
      }
      if (path.startsWith("/api/v1/app/chats")) {
        return Promise.resolve(jsonResponse(chatsIndexPayload({
          groups: [
            chatGroup({
              chats: [chatNav({ id: 10, title: "First" })],
              has_more: true
            })
          ]
        })))
      }

      return Promise.reject(new Error(`Unexpected fetch: ${path}`))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/"]}>
          <RecentChatsSidebar
            featureFlags={{}}
            onCloseDrawer={() => {}}
            onNotice={() => {}}
            prefix=""
            userPresent
          />
        </MemoryRouter>
      </QueryClientProvider>
    )

    await screen.findByText("First")
    fireEvent.click(screen.getByRole("button", { name: "Recent chats settings" }))
    fireEvent.click(screen.getByRole("button", { name: /Chats per group/ }))
    fireEvent.click(screen.getByRole("button", { name: "5" }))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(expect.stringContaining("per_group=5"), expect.anything())
    })

    fireEvent.click(await screen.findByRole("button", { name: "Show more" }))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(expect.stringContaining("/api/v1/app/chats/more?"), expect.anything())
      expect(fetchSpy).toHaveBeenCalledWith(expect.stringContaining("per_group=5"), expect.anything())
    })
  })

  it("hides the empty-group toggle when grouping by date", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(chatsIndexPayload()))

    renderSidebar([])

    fireEvent.click(screen.getByRole("button", { name: "Recent chats settings" }))
    expect(screen.getByRole("switch", { name: /Show empty groups/ })).toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: /Group by/ }))
    fireEvent.click(screen.getByRole("button", { name: "Date" }))

    await waitFor(() => {
      expect(screen.queryByRole("switch", { name: /Show empty groups/ })).not.toBeInTheDocument()
    })
  })

  it("hides chat type settings when no extra chat types are available", () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(chatsIndexPayload({ available_chat_types: ["agent"] })))
    renderSidebar([], { availableChatTypes: ["agent"] })

    fireEvent.click(screen.getByRole("button", { name: "Recent chats settings" }))

    expect(screen.queryByRole("button", { name: /Chat type/ })).not.toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: /Group by/ }))
    expect(screen.queryByRole("button", { name: "Chat type" })).not.toBeInTheDocument()
  })

  it("filters by chat type checkboxes and normalizes no selection back to all available types", async () => {
    const payload = chatsIndexPayload({ available_chat_types: ["agent", "group"] })
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(payload))
    renderSidebar([], { availableChatTypes: ["agent", "group"] })

    fireEvent.click(screen.getByRole("button", { name: "Recent chats settings" }))
    await screen.findByRole("button", { name: /Chat type/ })
    fireEvent.click(screen.getByRole("button", { name: /Chat type/ }))

    const agent = screen.getByRole("checkbox", { name: "Agent chats" })
    const group = screen.getByRole("checkbox", { name: "Group chats" })
    expect(agent).toHaveAttribute("aria-checked", "true")
    expect(group).toHaveAttribute("aria-checked", "true")

    fireEvent.click(group)

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(expect.stringContaining("chat_types=agent"), expect.anything())
    })

    fireEvent.click(agent)

    await waitFor(() => {
      expect(group).toHaveAttribute("aria-checked", "true")
      expect(agent).toHaveAttribute("aria-checked", "true")
      expect(fetchSpy).toHaveBeenCalledWith(expect.stringContaining("chat_types=agent%2Cgroup"), expect.anything())
    })
  })

  it("offers chat type grouping only when the chat type feature is visible", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(chatsIndexPayload({ available_chat_types: ["agent", "external"] })))
    renderSidebar([], { availableChatTypes: ["agent", "external"] })

    fireEvent.click(screen.getByRole("button", { name: "Recent chats settings" }))
    await screen.findByRole("button", { name: /Chat type/ })
    await screen.findByRole("button", { name: /Group by/ })
    fireEvent.click(screen.getByRole("button", { name: /Group by/ }))
    fireEvent.click(screen.getByRole("button", { name: "Chat type" }))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(expect.stringContaining("group_by=chat_type"), expect.anything())
    })
  })

  it("falls back from saved chat type grouping when the feature is no longer visible", async () => {
    window.localStorage.setItem(SIDEBAR_SETTINGS_KEY, JSON.stringify({
      status: "active",
      group_by: "chat_type",
      chat_types: ["external"],
      sort_by: "last_activity",
      show_empty_groups: true,
      per_group: 10
    }))
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(chatsIndexPayload({ available_chat_types: ["agent"] })))

    renderSidebar([], { availableChatTypes: ["agent"] })
    fireEvent.click(screen.getByRole("button", { name: "Recent chats settings" }))

    expect(screen.getByRole("button", { name: /Group by/ })).toHaveTextContent("Repository")
    await waitFor(() => {
      expect(fetchSpy.mock.calls.every(([input]) => !String(input).includes("group_by=chat_type"))).toBe(true)
    })
  })

  it("renders the desktop settings menu through a right-opening floating portal", () => {
    const restoreMatchMedia = withMatchMedia(true)
    try {
      renderSidebar([])

      fireEvent.click(screen.getByRole("button", { name: "Recent chats settings" }))

      const nav = screen.getByRole("navigation", { name: "Recent chats" })
      const menu = screen.getByTestId("recent-chats-settings-menu")
      expect(within(nav).queryByText("Status")).not.toBeInTheDocument()
      expect(menu).toHaveClass("w-64")
      expect(menu).not.toHaveClass("fixed")
    } finally {
      restoreMatchMedia()
    }
  })

  it("opens the settings menu full screen on mobile", () => {
    const restoreMatchMedia = withMatchMedia(false)
    try {
      renderSidebar([])

      fireEvent.click(screen.getByRole("button", { name: "Recent chats settings" }))

      const menu = screen.getByTestId("recent-chats-settings-menu")
      expect(menu).toHaveClass("fixed", "inset-0", "h-dvh", "w-screen")
      fireEvent.click(screen.getByRole("button", { name: "Close recent chats settings" }))
      expect(screen.queryByTestId("recent-chats-settings-menu")).not.toBeInTheDocument()
    } finally {
      restoreMatchMedia()
    }
  })

  it("loads more chat groups when the sidebar scrolls near the bottom", async () => {
    vi.stubGlobal("requestAnimationFrame", (callback: FrameRequestCallback) => {
      window.setTimeout(() => callback(0), 0)
      return 1
    })
    vi.stubGlobal("cancelAnimationFrame", vi.fn())
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(chatsIndexPayload({
      groups: [
        chatGroup({
          key: "date-2026-06-26",
          label: "Jun 26, 2026",
          group_by: "date",
          group_value: "2026-06-26",
          chats: [chatNav({ id: 2, title: "Older chat" })]
        })
      ],
      groups_has_more: false,
      groups_next_offset: null
    })))
    const scrollContainer = document.createElement("div")
    scrollContainer.style.overflowY = "auto"
    Object.defineProperty(scrollContainer, "scrollHeight", { configurable: true, value: 1000 })
    Object.defineProperty(scrollContainer, "clientHeight", { configurable: true, value: 700 })
    Object.defineProperty(scrollContainer, "scrollTop", { configurable: true, writable: true, value: 10 })
    document.body.appendChild(scrollContainer)

    try {
      const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
      queryClient.setQueryData<ChatsIndexPayload>(["chats", "recent"], chatsIndexPayload({
        groups: [
          chatGroup({
            key: "date-2026-06-27",
            label: "Today",
            group_by: "date",
            group_value: "2026-06-27",
            chats: [chatNav({ id: 1, title: "Recent chat" })]
          })
        ],
        groups_has_more: true,
        groups_next_offset: 24
      }))

      render(
        <QueryClientProvider client={queryClient}>
          <MemoryRouter initialEntries={["/"]}>
            <RecentChatsSidebar
              featureFlags={{}}
              onCloseDrawer={() => {}}
              onNotice={() => {}}
              prefix=""
              userPresent
            />
          </MemoryRouter>
        </QueryClientProvider>,
        { container: scrollContainer }
      )

      scrollContainer.dispatchEvent(new Event("scroll"))

      await screen.findByText("Older chat")
      expect(fetchSpy).toHaveBeenCalledWith(expect.stringContaining("group_offset=24"), expect.anything())
    } finally {
      scrollContainer.remove()
    }
  })

  it("shares loaded chat groups across mounted sidebar instances", async () => {
    vi.stubGlobal("requestAnimationFrame", (callback: FrameRequestCallback) => {
      window.setTimeout(() => callback(0), 0)
      return 1
    })
    vi.stubGlobal("cancelAnimationFrame", vi.fn())
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(chatsIndexPayload({
      groups: [
        chatGroup({
          key: "date-2026-06-26",
          label: "Jun 26, 2026",
          group_by: "date",
          group_value: "2026-06-26",
          chats: [chatNav({ id: 2, title: "Older chat" })]
        })
      ],
      groups_has_more: false,
      groups_next_offset: null
    })))
    const desktopScrollContainer = document.createElement("div")
    desktopScrollContainer.style.overflowY = "auto"
    Object.defineProperty(desktopScrollContainer, "scrollHeight", { configurable: true, value: 1000 })
    Object.defineProperty(desktopScrollContainer, "clientHeight", { configurable: true, value: 700 })
    Object.defineProperty(desktopScrollContainer, "scrollTop", { configurable: true, writable: true, value: 10 })
    document.body.appendChild(desktopScrollContainer)

    try {
      const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
      queryClient.setQueryData<ChatsIndexPayload>(["chats", "recent"], chatsIndexPayload({
        groups: [
          chatGroup({
            key: "date-2026-06-27",
            label: "Today",
            group_by: "date",
            group_value: "2026-06-27",
            chats: [chatNav({ id: 1, title: "Recent chat" })]
          })
        ],
        groups_has_more: true,
        groups_next_offset: 24
      }))

      const renderSidebars = (includeMobile: boolean) => (
        <QueryClientProvider client={queryClient}>
          <MemoryRouter initialEntries={["/"]}>
            <div data-testid="desktop-sidebar">
              <RecentChatsSidebar
                featureFlags={{}}
                onCloseDrawer={() => {}}
                onNotice={() => {}}
                prefix=""
                userPresent
              />
            </div>
            {includeMobile ? (
              <div data-testid="mobile-drawer">
                <RecentChatsSidebar
                  featureFlags={{}}
                  onCloseDrawer={() => {}}
                  onNotice={() => {}}
                  prefix=""
                  userPresent
                />
              </div>
            ) : null}
          </MemoryRouter>
        </QueryClientProvider>
      )

      const { rerender } = render(
        renderSidebars(false),
        { container: desktopScrollContainer }
      )

      expect(await within(screen.getByTestId("desktop-sidebar")).findByText("Older chat")).toBeInTheDocument()
      expect(fetchSpy).toHaveBeenCalledTimes(1)

      rerender(renderSidebars(true))

      expect(await within(screen.getByTestId("mobile-drawer")).findByText("Older chat")).toBeInTheDocument()
      expect(fetchSpy).toHaveBeenCalledTimes(1)
    } finally {
      desktopScrollContainer.remove()
    }
  })

  it("does not loop automatic group loading after a failed page request", async () => {
    vi.stubGlobal("requestAnimationFrame", (callback: FrameRequestCallback) => {
      window.setTimeout(() => callback(0), 0)
      return 1
    })
    vi.stubGlobal("cancelAnimationFrame", vi.fn())
    const fetchSpy = vi.spyOn(window, "fetch").mockRejectedValue(new Error("Network failed"))
    const scrollContainer = document.createElement("div")
    scrollContainer.style.overflowY = "auto"
    Object.defineProperty(scrollContainer, "scrollHeight", { configurable: true, value: 1000 })
    Object.defineProperty(scrollContainer, "clientHeight", { configurable: true, value: 700 })
    Object.defineProperty(scrollContainer, "scrollTop", { configurable: true, writable: true, value: 10 })
    document.body.appendChild(scrollContainer)

    try {
      const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
      queryClient.setQueryData<ChatsIndexPayload>(["chats", "recent"], chatsIndexPayload({
        groups: [
          chatGroup({
            key: "date-2026-06-27",
            label: "Today",
            group_by: "date",
            group_value: "2026-06-27",
            chats: [chatNav({ id: 1, title: "Recent chat" })]
          })
        ],
        groups_has_more: true,
        groups_next_offset: 24
      }))

      render(
        <QueryClientProvider client={queryClient}>
          <MemoryRouter initialEntries={["/"]}>
            <RecentChatsSidebar
              featureFlags={{}}
              onCloseDrawer={() => {}}
              onNotice={() => {}}
              prefix=""
              userPresent
            />
          </MemoryRouter>
        </QueryClientProvider>,
        { container: scrollContainer }
      )

      await waitFor(() => expect(fetchSpy).toHaveBeenCalledTimes(1))
      await act(async () => {
        await new Promise((resolve) => window.setTimeout(resolve, 20))
      })
      expect(fetchSpy).toHaveBeenCalledTimes(1)

      scrollContainer.dispatchEvent(new Event("scroll"))

      await waitFor(() => expect(fetchSpy).toHaveBeenCalledTimes(2))
    } finally {
      scrollContainer.remove()
    }
  })
})

describe("RecentChatsSidebar group chat icon", () => {
  it("shows a group icon for a group chat", () => {
    renderSidebar([chatNav({ id: 1, title: "Hello World Test", conversation_kind: "group" })])

    expect(screen.getByTestId("group-chat-icon")).toBeInTheDocument()
  })

  it("does not show a group icon for a direct chat", () => {
    renderSidebar([chatNav({ id: 1, title: "Direct Chat", conversation_kind: "direct" })])

    expect(screen.queryByTestId("group-chat-icon")).not.toBeInTheDocument()
  })

  it("does not show a group icon when conversation_kind is undefined", () => {
    renderSidebar([chatNav({ id: 1, title: "Legacy Chat" })])

    expect(screen.queryByTestId("group-chat-icon")).not.toBeInTheDocument()
  })
})

describe("RecentChatsSidebar goal marker", () => {
  it("marks chats with active or paused goals", () => {
    renderSidebar([
      chatNav({ id: 1, title: "Active Goal Chat", active_goal: chatGoal({ status: "active" }) }),
      chatNav({ id: 2, title: "Paused Goal Chat", active_goal: chatGoal({ id: 2, status: "paused" }) }),
      chatNav({ id: 3, title: "Completed Goal Chat", active_goal: chatGoal({ id: 3, status: "completed" }) }),
      chatNav({ id: 4, title: "No Goal Chat", active_goal: null })
    ])

    expect(screen.getByTitle("Active goal")).toBeInTheDocument()
    expect(screen.getByTitle("Paused goal")).toHaveClass("opacity-60")
    expect(screen.getAllByTestId("chat-goal-marker")).toHaveLength(2)
  })
})

describe("RecentChatsSidebar action and marker slot", () => {
  it("uses the same fixed-width slot for section controls, markers, and row actions", () => {
    renderSidebar([], {
      groups: [
        chatGroup({
          key: "repository-7",
          label: "acme/widgets",
          repository_id: 7,
          group_by: "repository",
          group_value: "7",
          chats: [
            chatNav({
              id: 1,
              title: "Busy unread chat",
              active_goal: chatGoal(),
              coding_checkout_uncommitted: true,
              pending_proposal_count: 1,
              scratchpad_items_count: 1,
              turn_in_flight: true,
              unread: true
            })
          ]
        })
      ],
      onStartChat: vi.fn()
    })

    const headerSlots = screen.getAllByTestId("recent-chat-header-action-slot")
    const markerSlot = screen.getByTestId("recent-chat-marker-slot")
    const actionSlot = screen.getByTestId("recent-chat-action-slot")

    expect(headerSlots.length).toBeGreaterThanOrEqual(2)
    headerSlots.forEach((slot) => expect(slot).toHaveClass("h-6", "w-6", "items-center", "justify-center"))
    expect(headerSlots.find((slot) => within(slot).queryByRole("button", { name: "New chat in acme/widgets" }))?.closest("h2")).toHaveClass("pr-2")
    expect(markerSlot).toHaveClass("h-6", "min-w-6", "items-center", "justify-end", "pr-[0.3125rem]")
    expect(actionSlot).toHaveClass("right-2", "top-1/2", "-translate-y-1/2")
    expect(actionSlot.querySelector("button")).toHaveClass("h-6", "w-6")
    expect(screen.getByTitle("Chat turn active")).toHaveClass("h-3.5", "w-3.5", "items-center", "justify-center")
    expect(screen.getByTitle("Active goal")).toHaveClass("h-3.5", "w-3.5", "items-center", "justify-center")
    expect(markerSlot.firstElementChild).toHaveClass("flex", "items-center", "gap-1")
    expect(markerSlot.firstElementChild).not.toHaveClass("absolute")
  })

  it("replaces markers with the actions button while the row menu is open", () => {
    renderSidebar([chatNav({ id: 7, title: "Roadmap sync", active_goal: chatGoal(), unread: true })])

    const markerSlot = screen.getByTestId("recent-chat-marker-slot")
    const trigger = screen.getByRole("button", { name: "Chat actions for Roadmap sync" })

    expect(markerSlot).not.toHaveClass("invisible")
    expect(markerSlot.closest("a")).toBe(screen.getByRole("link", { name: "Roadmap sync" }))

    fireEvent.click(trigger)

    expect(markerSlot).toHaveClass("invisible")
    expect(markerSlot).not.toHaveClass("hidden")
    expect(trigger).toHaveClass("opacity-100")
    expect(trigger).toHaveAttribute("aria-expanded", "true")
  })
})

describe("RecentChatsSidebar drag-over blink and navigate", () => {
  beforeEach(() => vi.useFakeTimers())
  afterEach(() => vi.useRealTimers())

  it("dragenter on a chat row marks that chat as blinking", () => {
    renderSidebar([chatNav({ id: 1, title: "Drag Target" })])

    const chatLink = screen.getByRole("link", { name: "Drag Target" })
    const chatRow = chatLink.parentElement!

    fireEvent.dragEnter(chatRow)

    expect(chatRow.className).toContain("animate-drag-blink")
  })

  it("dragleave from a chat row cancels the pending navigation", () => {
    const closeSpy = vi.fn()
    renderSidebar([chatNav({ id: 1, title: "Drag Target", chat_path: "/chats/1" })], { onCloseDrawer: closeSpy })

    const chatLink = screen.getByRole("link", { name: "Drag Target" })
    const chatRow = chatLink.parentElement!

    fireEvent.dragEnter(chatRow)
    // Leave the row entirely (relatedTarget is null — cursor left the element)
    fireEvent.dragLeave(chatRow, { relatedTarget: null })

    act(() => { vi.advanceTimersByTime(1000) })

    // Location stays at "/" because navigation was cancelled
    expect(screen.getByTestId("location")).toHaveTextContent("/")
    expect(closeSpy).not.toHaveBeenCalled()
  })

  it("navigates to the chat after holding 1000ms and calls onCloseDrawer", () => {
    const closeSpy = vi.fn()
    renderSidebar([chatNav({ id: 1, title: "Drag Target", chat_path: "/chats/1" })], { onCloseDrawer: closeSpy })

    const chatLink = screen.getByRole("link", { name: "Drag Target" })
    const chatRow = chatLink.parentElement!

    fireEvent.dragEnter(chatRow)

    expect(screen.getByTestId("location")).toHaveTextContent("/")

    act(() => { vi.advanceTimersByTime(1000) })

    expect(screen.getByTestId("location")).toHaveTextContent("/chats/1")
    expect(closeSpy).toHaveBeenCalledTimes(1)
  })
})

describe("RecentChatsSidebar auto-scroll during drag", () => {
  let scrollContainer: HTMLDivElement

  beforeEach(() => {
    scrollContainer = document.createElement("div")
    scrollContainer.style.overflowY = "auto"
    document.body.appendChild(scrollContainer)
  })

  afterEach(() => {
    scrollContainer.remove()
  })

  it("dragover near the top triggers scrollBy upward", () => {
    vi.spyOn(scrollContainer, "getBoundingClientRect").mockReturnValue({
      top: 0, bottom: 300, left: 0, right: 200, height: 300, width: 200,
      x: 0, y: 0, toJSON: vi.fn()
    } as DOMRect)
    // JSDOM does not implement scrollBy as an own property; define it so it can be observed.
    const scrollBy = vi.fn()
    Object.defineProperty(scrollContainer, "scrollBy", { value: scrollBy, writable: true, configurable: true })

    // Stub requestAnimationFrame globally before the event fires so the callback is captured.
    let capturedCallback: FrameRequestCallback | null = null
    vi.stubGlobal("requestAnimationFrame", (cb: FrameRequestCallback) => {
      capturedCallback = cb
      return 1
    })

    renderSidebar(
      [chatNav({ id: 1, title: "Scroll Target" })],
      { renderOptions: { container: scrollContainer } }
    )

    const nav = screen.getByRole("navigation", { name: "Recent chats" })
    // JSDOM does not implement DragEvent, so fireEvent.dragOver produces an event
    // whose clientY is undefined. Dispatch a MouseEvent (type "dragover") instead:
    // React's onDragOver intercepts it identically and MouseEvent correctly carries clientY.
    // clientY: 30 → relY = 30 - rect.top (0) = 30, which is < 60 (top edge zone)
    nav.parentElement!.dispatchEvent(
      new MouseEvent("dragover", { bubbles: true, cancelable: true, clientY: 30 })
    )

    // Invoke the captured RAF callback once to trigger one scrollBy call
    expect(capturedCallback).not.toBeNull()
    if (capturedCallback) act(() => { (capturedCallback as FrameRequestCallback)(0) })

    expect(scrollBy).toHaveBeenCalledWith(0, -8)
  })
})

describe("RecentChatsSidebar mark-as-read/unread label", () => {
  it("shows 'Mark as read' for an unread chat", () => {
    renderSidebar([chatNav({ id: 1, title: "Unread Chat", unread: true })])

    fireEvent.click(screen.getByRole("button", { name: "Chat actions for Unread Chat" }))

    expect(screen.getByRole("button", { name: "Mark as read" })).toBeInTheDocument()
  })

  it("shows 'Mark as unread' for a read chat", () => {
    renderSidebar([chatNav({ id: 1, title: "Read Chat", unread: false })])

    fireEvent.click(screen.getByRole("button", { name: "Chat actions for Read Chat" }))

    expect(screen.getByRole("button", { name: "Mark as unread" })).toBeInTheDocument()
  })
})

describe("RecentChatsSidebar bookmarks menu", () => {
  function renderWithBookmarks(bookmarks: ChatBookmark[], chatId = 1) {
    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    queryClient.setQueryData<ChatsIndexPayload>(["chats", "recent"], chatsIndexPayload({
      groups: [chatGroup({ chats: [chatNav({ id: chatId, title: "Chat With Bookmarks" })] })]
    }))
    queryClient.setQueryData(["chats", String(chatId), ""], { bookmarks } as unknown as ChatPayload)

    return render(
      <QueryClientProvider client={queryClient}>
        <MemoryRouter initialEntries={["/"]}>
          <RecentChatsSidebar
            featureFlags={{}}
            onCloseDrawer={() => {}}
            onNotice={() => {}}
            prefix=""
            userPresent
          />
        </MemoryRouter>
      </QueryClientProvider>
    )
  }

  it("wraps bookmark list in a scrollable container when there are more than 6 bookmarks", () => {
    const bookmarks = Array.from({ length: 7 }, (_, i): ChatBookmark => ({
      id: i + 1,
      label: `Bookmark ${i + 1}`,
      chat_message_id: i + 100
    }))
    renderWithBookmarks(bookmarks)

    fireEvent.click(screen.getByRole("button", { name: "Chat actions for Chat With Bookmarks" }))

    const firstLink = screen.getByRole("link", { name: "Bookmark 1" })
    const scrollContainer = firstLink.closest("div")
    expect(scrollContainer).toHaveClass("overflow-y-auto")
    expect(scrollContainer).toHaveClass("max-h-48")
  })

  it("renders a divider between the bookmark area and the Pin button when there are bookmarks", () => {
    renderWithBookmarks([{ id: 1, label: "A bookmark", chat_message_id: 10 }])

    fireEvent.click(screen.getByRole("button", { name: "Chat actions for Chat With Bookmarks" }))

    const pinButton = screen.getByRole("button", { name: /pin/i })
    expect(pinButton.previousElementSibling).toHaveClass("border-t")
  })

  it("renders a divider between the bookmark area and the Pin button when there are no bookmarks", () => {
    renderWithBookmarks([])

    fireEvent.click(screen.getByRole("button", { name: "Chat actions for Chat With Bookmarks" }))

    const pinButton = screen.getByRole("button", { name: /pin/i })
    expect(pinButton.previousElementSibling).toHaveClass("border-t")
  })
})

describe("RecentChatsSidebar overflow menu slug", () => {
  afterEach(() => {
    vi.restoreAllMocks()
  })

  it("shows a copyable CHAT-<id> slug without a hover preview popup", async () => {
    const clipboardWrite = vi.fn().mockResolvedValue(undefined)
    Object.assign(navigator, { clipboard: { writeText: clipboardWrite } })
    const fetchSpy = vi.spyOn(window, "fetch")

    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    queryClient.setQueryData<ChatsIndexPayload>(["chats", "recent"], chatsIndexPayload({
      groups: [chatGroup({ chats: [chatNav({ id: 42, title: "Roadmap sync" })] })]
    }))

    render(
      <QueryClientProvider client={queryClient}>
        <MemoryRouter initialEntries={["/"]}>
          <RecentChatsSidebar
            featureFlags={{}}
            onCloseDrawer={() => {}}
            onNotice={() => {}}
            prefix=""
            userPresent
          />
        </MemoryRouter>
      </QueryClientProvider>
    )

    fireEvent.click(screen.getByRole("button", { name: "Chat actions for Roadmap sync" }))

    const copySlugButton = screen.getByRole("button", { name: "Copy CHAT-42 to clipboard" })
    expect(copySlugButton).toHaveTextContent("CHAT-42")

    fireEvent.click(copySlugButton)
    await waitFor(() => expect(clipboardWrite).toHaveBeenCalledWith("CHAT-42"))

    fireEvent.mouseEnter(copySlugButton)
    fireEvent.mouseEnter(copySlugButton.parentElement!)
    expect(screen.queryByText("See more")).not.toBeInTheDocument()
    expect(fetchSpy.mock.calls.some(([input]) => typeof input === "string" && input.includes("/preview"))).toBe(false)
  })

  it("renders the dropdown through a portal outside the sidebar navigation so flip/shift can escape its clipping ancestor", () => {
    renderSidebar([chatNav({ id: 7, title: "Roadmap sync" })])

    fireEvent.click(screen.getByRole("button", { name: "Chat actions for Roadmap sync" }))

    const nav = screen.getByRole("navigation", { name: "Recent chats" })
    const renameButton = screen.getByRole("button", { name: "Rename" })
    expect(within(nav).queryByRole("button", { name: "Rename" })).not.toBeInTheDocument()
    expect(renameButton).toBeInTheDocument()
    expect(renameButton.closest("div.z-50")).not.toBeNull()
  })

  it("does not close the dropdown when a pointerdown event targets its portaled content", () => {
    renderSidebar([chatNav({ id: 7, title: "Roadmap sync" })])

    const trigger = screen.getByRole("button", { name: "Chat actions for Roadmap sync" })
    fireEvent.click(trigger)
    expect(trigger).toHaveAttribute("aria-expanded", "true")

    // Regression guard: the dropdown now renders through a FloatingPortal, so
    // a pointerdown on its content is outside the trigger's own DOM subtree.
    // Without wiring that portal ref into the outside-pointer check, this
    // would be (wrongly) treated as an outside click and close the menu.
    fireEvent.pointerDown(screen.getByRole("button", { name: "Copy CHAT-7 to clipboard" }))

    expect(trigger).toHaveAttribute("aria-expanded", "true")
    expect(screen.getByRole("button", { name: "Rename" })).toBeInTheDocument()
  })
})

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

function chatGoal(overrides: Partial<ChatGoal> = {}): ChatGoal {
  return {
    id: 1,
    chat_session_id: 1,
    user_id: 1,
    repository_id: null,
    prompt: "Keep making progress",
    completion_condition: null,
    mode_snapshot: {},
    status: "active",
    approval_policy: "manual",
    auto_file_proposals: false,
    auto_submit_jobs: false,
    iteration_count: 0,
    terminal_at: null,
    terminal_reason: null,
    terminal_details: null,
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
