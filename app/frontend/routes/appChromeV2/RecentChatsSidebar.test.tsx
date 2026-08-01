import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { act, fireEvent, render, screen } from "@testing-library/react"
import { MemoryRouter, useLocation } from "react-router-dom"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import type { ChatBookmark, ChatGroupRecord, ChatNavRecord, ChatPayload, ChatsIndexPayload } from "../../api/chats"
import { RecentChatsSidebar } from "./RecentChatsSidebar"

function LocationProbe() {
  const location = useLocation()
  return <div data-testid="location">{location.pathname}</div>
}

function renderSidebar(
  chats: ChatNavRecord[],
  options: { featureFlags?: Record<string, boolean>; prefix?: string; onCloseDrawer?: () => void; renderOptions?: Parameters<typeof render>[1]; supervisorChat?: ChatNavRecord | null } = {}
) {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  queryClient.setQueryData<ChatsIndexPayload>(["chats", "recent"], chatsIndexPayload({
    supervisor_chat: options.supervisorChat,
    groups: [chatGroup({ chats })]
  }))

  return render(
    <QueryClientProvider client={queryClient}>
      <MemoryRouter initialEntries={["/"]}>
        <RecentChatsSidebar
          featureFlags={options.featureFlags ?? {}}
          onCloseDrawer={options.onCloseDrawer ?? (() => {})}
          onNotice={() => {}}
          prefix={options.prefix ?? ""}
          userPresent
        />
        <LocationProbe />
      </MemoryRouter>
    </QueryClientProvider>,
    options.renderOptions
  )
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
          message: "Codex usage limit reached. This item uses Codex until usage resets or you switch providers."
        }
      })
    ])

    expect(screen.getByRole("img", { name: /Codex usage limit reached/ })).toBeInTheDocument()
  })

  it("does not highlight a chat as active when the URL is not /chats/:id even if current=true", () => {
    renderSidebar([chatNav({ id: 1, title: "My Chat", current: true })])

    const link = screen.getByRole("link", { name: "My Chat" })
    // Active chats get bg-blue-50; inactive chats only get bg-blue-50 on hover.
    // The class string contains "bg-blue-50" only when active.
    expect(link.className).not.toContain("bg-blue-50")
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
    expect(link.className).toContain("bg-blue-50")
  })
})

describe("RecentChatsSidebar supervisor chat", () => {
  it("renders supervisor above ordinary chat groups with unread severity count", () => {
    renderSidebar(
      [chatNav({ id: 2, title: "Planning" })],
      {
        featureFlags: { admin_supervisor_chat: true },
        supervisorChat: chatNav({
          id: 1,
          title: "Supervisor",
          system_kind: "supervisor",
          unread: true,
          supervisor_unread_count: 4,
          supervisor_unread_severity: "critical"
        })
      }
    )

    const links = screen.getAllByRole("link")
    expect(links[0]).toHaveTextContent("Supervisor")
    expect(links[0]).toHaveTextContent("Admin")
    expect(links[0]).toHaveTextContent("4")
    expect(links[1]).toHaveTextContent("Planning")
  })

  it("hides supervisor when the feature flag is off", () => {
    renderSidebar(
      [chatNav({ id: 2, title: "Planning" })],
      {
        featureFlags: { admin_supervisor_chat: false },
        supervisorChat: chatNav({ id: 1, title: "Supervisor", system_kind: "supervisor" })
      }
    )

    expect(screen.queryByRole("link", { name: /Supervisor/ })).not.toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Planning" })).toBeInTheDocument()
  })

  it("hides supervisor for non-admin payloads even when the feature flag is on", () => {
    renderSidebar(
      [chatNav({ id: 2, title: "Planning" })],
      { featureFlags: { admin_supervisor_chat: true }, supervisorChat: null }
    )

    expect(screen.queryByRole("link", { name: /Supervisor/ })).not.toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Planning" })).toBeInTheDocument()
  })

  it("does not render supervisor chats from ordinary groups", () => {
    renderSidebar([
      chatNav({ id: 1, title: "Supervisor", system_kind: "supervisor" }),
      chatNav({ id: 2, title: "Planning" })
    ])

    expect(screen.queryByRole("link", { name: /Supervisor/ })).not.toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Planning" })).toBeInTheDocument()
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
