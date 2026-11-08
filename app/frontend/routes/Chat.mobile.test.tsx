import { act, fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { describe, expect, it, vi } from "vitest"
import { MemoryRouter } from "react-router-dom"
import { App } from "./App"
import { AppChromeV2 } from "./AppChromeV2"
import type { BootstrapPayload } from "../api/bootstrap"
import { bootstrapPayload } from "../test/app/bootstrap"
import { chatPayload } from "../test/app/chatPayloads"
import { mockMediaQuery, mockViewportWidth, setScrollMetrics, setViewportHeight, stubVisualViewport } from "../test/app/viewport"
import { installAppTestLifecycle } from "../test/app/lifecycle"

vi.mock("@rails/actioncable", async () => (await import("../test/app/appMocks")).actionCableModule())
vi.mock("@excalidraw/excalidraw", async () => (await import("../test/app/appMocks")).excalidrawModule())
vi.mock("html2canvas-pro", async () => (await import("../test/app/appMocks")).html2canvasModule())

describe("App chat mobile", () => {
  installAppTestLifecycle()

  it("renders chat tabs above the chat panel on mobile", async () => {
    const restoreMedia = mockMediaQuery(false)
    vi.spyOn(window, "fetch").mockImplementation(
      async () => new Response(JSON.stringify(chatPayload()), { status: 200, headers: { "Content-Type": "application/json" } })
    )

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      expect(await screen.findByText("Discuss aqueducts.")).toBeInTheDocument()
      expect(screen.queryByRole("heading", { name: "Aqueduct planning" })).not.toBeInTheDocument()
      expect(screen.queryByRole("link", { name: "New chat" })).not.toBeInTheDocument()
      const mobileTabs = screen.getByRole("navigation", { name: "Chat mobile tabs" })
      const mobileTabsShell = screen.getByTestId("mobile-chat-tabs-shell")
      expect(mobileTabs.parentElement).not.toHaveClass("rounded")
      expect(mobileTabs.parentElement).not.toHaveClass("border")
      expect(mobileTabsShell).toHaveClass("absolute", "inset-x-0", "top-[var(--mobile-chat-app-header-height,0px)]")
      expect(mobileTabsShell).not.toHaveClass("top-0")
      expect(mobileTabsShell).not.toHaveClass("relative")
      expect(mobileTabs.parentElement?.lastElementChild).not.toHaveClass("p-3")
      expect(within(mobileTabsShell).getByText("Tokens: 12.4k in / 3.2k out · $0.0123")).toBeInTheDocument()
      expect(within(mobileTabs).getByRole("button", { name: "Chat" })).toHaveClass("border-brand")
      expect(within(mobileTabs).getByRole("button", { name: "Whiteboard" })).toBeInTheDocument()
      expect(within(mobileTabs).getByRole("button", { name: "Files" })).toBeInTheDocument()
      expect(within(mobileTabs).queryByRole("button", { name: "Chats" })).not.toBeInTheDocument()
      expect(screen.queryByRole("navigation", { name: "Chat workspace tabs" })).not.toBeInTheDocument()
      expect(screen.getByRole("main", { name: "Chat" })).toHaveClass("h-full", "lg:[height:100%]")
      expect(screen.getByRole("main", { name: "Chat" })).not.toHaveClass("[height:calc(var(--chat-visual-viewport-height,100dvh)-4.5rem)]")
      // The chrome's scroll container is a div now, not a second <main>
      // nested around the route's own (see AppChromeV2).
      const chromeScrollPane = screen.getByTestId("app-scroll-pane")
      expect(chromeScrollPane).toHaveClass("relative", "flex", "flex-col", "overflow-hidden")
      expect(chromeScrollPane).not.toHaveClass("overflow-auto")
      expect(chromeScrollPane.style.getPropertyValue("--mobile-chrome-top-overlap-height")).toBe("72px")
      expect(mobileTabs).toHaveClass("min-h-[44px]", "px-[max(0.5rem,env(safe-area-inset-left))]")
      const mobileChatContentShell = screen.getByTestId("mobile-chat-content-shell")
      const mobileChatRouteShell = screen.getByTestId("mobile-chat-route-shell")
      const mobileChatSurface = screen.getByTestId("mobile-chat-surface")
      expect(mobileChatContentShell).toHaveClass("flex", "min-h-0", "flex-1", "flex-col")
      expect(mobileChatContentShell.className).not.toContain("pt-[var(--mobile-chat-app-header-height")
      expect(mobileChatRouteShell).toHaveClass("relative", "flex", "min-h-0", "flex-1", "flex-col")
      expect(mobileChatRouteShell.style.getPropertyValue("--mobile-chat-stream-top-breathing-room")).toBe(
        "calc(var(--mobile-chat-app-header-height,0px) + 70px + 0.75rem)"
      )
      expect(mobileChatSurface).toHaveClass("flex", "min-h-0", "w-full", "flex-1")
      expect(mobileChatSurface.className).not.toContain("pt-[var(--mobile-chat-top-inset")
      const stream = screen.getByTestId("chat-message-stream")
      expect(stream).toHaveClass("h-full", "min-h-0", "overflow-x-hidden", "overflow-y-auto", "overscroll-contain", "p-2")
      expect(stream).not.toHaveClass("pt-12")
      expect(stream.style.paddingTop).toBe("var(--mobile-chat-stream-top-breathing-room,1rem)")
      expect(screen.getByPlaceholderText("Ask about this repository...")).toHaveClass("min-h-11", "text-base", "sm:min-h-9", "sm:text-sm")
      const attachmentButton = screen.getByRole("button", { name: "Add attachment" })
      expect(attachmentButton).toHaveClass("h-8", "w-8", "min-h-11", "min-w-11", "sm:min-h-0", "sm:min-w-0")
      expect(attachmentButton.className).toContain("!border-transparent")
      expect(attachmentButton.className).toContain("!bg-transparent")
      expect(attachmentButton.className).toContain("hover:bg-gray-100")
      expect(attachmentButton.className).toContain("focus-visible:ring-2")
      expect(screen.getByRole("button", { name: "Effort" })).toHaveClass("min-h-11", "sm:min-h-0")
      expect(screen.getByText("Discuss aqueducts.").parentElement?.parentElement).toHaveClass("px-0", "sm:rounded")

      fireEvent.click(within(mobileTabs).getByRole("button", { name: "Whiteboard" }))
      expect(within(mobileTabs).getByRole("button", { name: "Whiteboard" })).toHaveClass("border-brand")
      expect(within(mobileTabsShell).queryByText("Tokens: 12.4k in / 3.2k out · $0.0123")).not.toBeInTheDocument()
      expect(screen.queryByTestId("chat-message-stream")).not.toBeInTheDocument()
      expect(await screen.findByRole("complementary", { name: "Chat workspace" })).toHaveClass("h-full", "min-h-0", "w-full", "flex-1")
      expect(screen.queryByText(/^Version \d+$/)).not.toBeInTheDocument()

      fireEvent.click(within(mobileTabs).getByRole("button", { name: "Files" }))
      expect(within(mobileTabs).getByRole("button", { name: "Files" })).toHaveClass("border-brand")
      expect(screen.getByRole("complementary", { name: "Chat workspace" })).toHaveClass("h-full", "min-h-0", "w-full", "flex-1")

      fireEvent.click(within(mobileTabs).getByRole("button", { name: "Chat" }))
      expect(within(mobileTabsShell).getByText("Tokens: 12.4k in / 3.2k out · $0.0123")).toBeInTheDocument()
      expect(screen.getByTestId("chat-message-stream")).toBeInTheDocument()
      expect(screen.getByPlaceholderText("Ask about this repository...")).toBeInTheDocument()
    } finally {
      restoreMedia()
    }
  })

  it("renders one usage bar in the desktop-shell mobile-workspace breakpoint gap", async () => {
    const restoreMedia = mockViewportWidth(1100)
    vi.spyOn(window, "fetch").mockImplementation(
      async () => new Response(JSON.stringify(chatPayload()), { status: 200, headers: { "Content-Type": "application/json" } })
    )

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      expect(await screen.findByRole("navigation", { name: "Chat mobile tabs" })).toBeInTheDocument()
      expect(screen.getAllByText("Tokens: 12.4k in / 3.2k out · $0.0123")).toHaveLength(1)
    } finally {
      restoreMedia()
    }
  })

  it("auto-hides the mobile chat header from real chat scrolling and ignores interactive content taps", async () => {
    const restoreMedia = mockMediaQuery(false)
    const bootstrap = bootstrapPayload({
      current_user: {
        ...bootstrapPayload().current_user,
        mobile_chat_auto_hide_header: true
      }
    })
    const script = document.createElement("script")
    script.id = "syrus-bootstrap-data"
    script.type = "application/json"
    script.textContent = JSON.stringify(bootstrap)
    document.body.appendChild(script)
    vi.spyOn(window, "fetch").mockImplementation(async (input) => {
      const path = String(input)
      if (path.endsWith("/api/v1/app/bootstrap"))
        return new Response(JSON.stringify(bootstrap), { status: 200, headers: { "Content-Type": "application/json" } })

      return new Response(
        JSON.stringify(
          chatPayload({
            messages: [
              {
                type: "message",
                id: 9,
                role: "assistant",
                tool_name: null,
                content: { text: "Read [Example](https://example.com)." },
                text: "Read [Example](https://example.com).",
                bookmarkable: true
              }
            ]
          })
        ),
        { status: 200, headers: { "Content-Type": "application/json" } }
      )
    })

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      const stream = await screen.findByTestId("chat-message-stream")
      const header = screen.getByTestId("mobile-app-header")
      const mobileTabs = screen.getByRole("navigation", { name: "Chat mobile tabs" })
      const mobileTabsShell = screen.getByTestId("mobile-chat-tabs-shell")
      const mobileChatShell = mobileTabsShell.parentElement as HTMLElement
      const mobileContentLayer = mobileTabsShell.nextElementSibling as HTMLElement
      expect(screen.getByTestId("app-scroll-pane").style.getPropertyValue("--mobile-chat-app-header-height")).toBe("72px")
      expect(mobileTabsShell).toHaveClass("top-[var(--mobile-chat-app-header-height,0px)]")
      expect(mobileTabsShell).not.toHaveClass("top-0")
      expect(mobileChatShell.style.getPropertyValue("--mobile-chat-stream-top-breathing-room")).toBe(
        "calc(var(--mobile-chat-app-header-height,0px) + 70px + 0.75rem)"
      )
      expect(mobileContentLayer).toHaveClass("flex", "min-h-0", "w-full", "flex-1")
      expect(mobileContentLayer.className).not.toContain("pt-[var(--mobile-chat-top-inset")
      expect(stream.style.paddingTop).toBe("var(--mobile-chat-stream-top-breathing-room,1rem)")
      setScrollMetrics(stream, { scrollHeight: 1600, clientHeight: 400, scrollTop: 100 })
      fireEvent.scroll(stream, { target: { scrollTop: 100 } })
      expect(header).toHaveStyle({ transform: "translateY(-0px)" })
      expect(mobileTabsShell).toHaveStyle({ opacity: "1", transform: "translateY(-0px)" })

      setScrollMetrics(stream, { scrollHeight: 1600, clientHeight: 400, scrollTop: 200 })
      fireEvent.touchMove(stream)
      fireEvent.scroll(stream, { target: { scrollTop: 200 } })
      expect(header).toHaveStyle({ opacity: "0", transform: "translateY(-142px)" })
      expect(header).not.toHaveStyle({ marginBottom: "-142px" })
      expect(mobileTabsShell).toHaveStyle({ opacity: "0", transform: "translateY(-142px)" })

      for (const scrollTop of [300, 400, 500, 600, 700]) {
        setScrollMetrics(stream, { scrollHeight: 1600, clientHeight: 400, scrollTop })
        fireEvent.touchMove(stream)
        fireEvent.scroll(stream, { target: { scrollTop } })
      }

      expect(header).toHaveStyle({ opacity: "0", transform: "translateY(-142px)" })
      expect(header).not.toHaveStyle({ marginBottom: "-142px" })
      expect(mobileTabsShell).toHaveStyle({ opacity: "0", transform: "translateY(-142px)" })
      expect(screen.getByTestId("mobile-chat-hidden-header-sidebar-button")).toHaveAccessibleName("Open sidebar")
      const hiddenHeaderScrim = screen.getByTestId("mobile-chat-hidden-header-scrim")
      expect(hiddenHeaderScrim).toHaveClass("h-32", "backdrop-blur-md", "backdrop-saturate-150")
      expect(hiddenHeaderScrim).not.toHaveClass("h-14")
      expect(stream).toHaveAttribute("data-mobile-header-hidden", "true")
      expect(stream).not.toHaveClass("pt-12")
      expect(stream.style.paddingTop).toBe("var(--mobile-chat-stream-top-breathing-room,1rem)")
      const streamContent = screen.getByTestId("chat-message-stream-content")
      expect(streamContent).toHaveAttribute("data-mobile-header-hidden", "true")
      expect(streamContent).toHaveClass("transition-transform", "motion-reduce:transition-none")
      expect(streamContent).toHaveStyle({ transform: "translateY(-2rem)" })
      expect(within(mobileTabs).getByRole("button", { name: "Chat" })).toHaveClass("border-brand")

      fireEvent.click(screen.getByRole("link", { name: "Example" }))
      expect(header).toHaveStyle({ transform: "translateY(-142px)" })
      expect(mobileTabsShell).toHaveStyle({ transform: "translateY(-142px)" })

      fireEvent.click(stream)
      expect(header).toHaveStyle({ transform: "translateY(-0px)" })
      expect(screen.queryByTestId("mobile-chat-hidden-header-scrim")).not.toBeInTheDocument()

      fireEvent.click(stream)
      expect(header).toHaveStyle({ transform: "translateY(-142px)" })
      expect(header).not.toHaveStyle({ marginBottom: "-142px" })
    } finally {
      restoreMedia()
      script.remove()
    }
  })

  it("keeps the mobile chat header revealed during top rubber-band scroll jitter", async () => {
    const restoreMedia = mockMediaQuery(false)
    const bootstrap = bootstrapPayload({
      current_user: {
        ...bootstrapPayload().current_user,
        mobile_chat_auto_hide_header: true
      }
    })
    const script = document.createElement("script")
    script.id = "syrus-bootstrap-data"
    script.type = "application/json"
    script.textContent = JSON.stringify(bootstrap)
    document.body.appendChild(script)
    vi.spyOn(window, "fetch").mockImplementation(async (input) => {
      const path = String(input)
      if (path.endsWith("/api/v1/app/bootstrap"))
        return new Response(JSON.stringify(bootstrap), { status: 200, headers: { "Content-Type": "application/json" } })

      return new Response(JSON.stringify(chatPayload()), { status: 200, headers: { "Content-Type": "application/json" } })
    })

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      const stream = await screen.findByTestId("chat-message-stream")
      const header = screen.getByTestId("mobile-app-header")
      setScrollMetrics(stream, { scrollHeight: 1200, clientHeight: 400, scrollTop: 0 })

      fireEvent.touchMove(stream)
      setScrollMetrics(stream, { scrollHeight: 1200, clientHeight: 400, scrollTop: 6 })
      fireEvent.scroll(stream)
      setScrollMetrics(stream, { scrollHeight: 1200, clientHeight: 400, scrollTop: 0 })
      fireEvent.scroll(stream)

      expect(header).toHaveStyle({ transform: "translateY(-0px)" })

      fireEvent.touchMove(stream)
      setScrollMetrics(stream, { scrollHeight: 1200, clientHeight: 400, scrollTop: 120 })
      fireEvent.scroll(stream)

      expect(header).toHaveStyle({ opacity: "0", transform: "translateY(-142px)" })
      expect(header).not.toHaveStyle({ marginBottom: "-142px" })

      fireEvent.touchMove(stream)
      setScrollMetrics(stream, { scrollHeight: 1200, clientHeight: 400, scrollTop: 0 })
      fireEvent.scroll(stream)

      expect(header).toHaveStyle({ transform: "translateY(-0px)" })
    } finally {
      restoreMedia()
      script.remove()
    }
  })

  it("does not oscillate the mobile chat header while the new-message button smooth-scrolls to bottom", async () => {
    const restoreMedia = mockMediaQuery(false)
    const bootstrap = bootstrapPayload({
      current_user: {
        ...bootstrapPayload().current_user,
        mobile_chat_auto_hide_header: true
      }
    })
    const script = document.createElement("script")
    script.id = "syrus-bootstrap-data"
    script.type = "application/json"
    script.textContent = JSON.stringify(bootstrap)
    document.body.appendChild(script)
    vi.spyOn(window, "fetch").mockImplementation(async (input) => {
      const path = String(input)
      if (path.endsWith("/api/v1/app/bootstrap"))
        return new Response(JSON.stringify(bootstrap), { status: 200, headers: { "Content-Type": "application/json" } })

      return new Response(JSON.stringify(chatPayload()), { status: 200, headers: { "Content-Type": "application/json" } })
    })
    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })

    try {
      render(
        <QueryClientProvider client={queryClient}>
          <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      const stream = await screen.findByTestId("chat-message-stream")
      const header = screen.getByTestId("mobile-app-header")
      setScrollMetrics(stream, { scrollHeight: 1000, clientHeight: 400, scrollTop: 200 })
      fireEvent.scroll(stream)
      fireEvent.touchMove(stream)
      setScrollMetrics(stream, { scrollHeight: 1300, clientHeight: 400, scrollTop: 200 })

      act(() => {
        queryClient.setQueryData(
          ["chats", "8", ""],
          chatPayload({
            messages: [
              ...chatPayload().messages,
              {
                type: "message",
                id: 10,
                role: "assistant",
                text: "First new note.",
                bookmarkable: true
              },
              {
                type: "message",
                id: 11,
                role: "assistant",
                text: "Second new note.",
                bookmarkable: true
              }
            ]
          })
        )
      })

      const button = await screen.findByRole("button", { name: "2 new messages" })
      Object.defineProperty(stream, "scrollTo", {
        configurable: true,
        value: vi.fn(({ top }: ScrollToOptions) => {
          stream.scrollTop = Number(top)
        })
      })

      fireEvent.click(button)
      for (const scrollTop of [500, 460, 900, 1300]) {
        setScrollMetrics(stream, { scrollHeight: 1300, clientHeight: 400, scrollTop })
        fireEvent.scroll(stream)
        expect(header).toHaveStyle({ transform: "translateY(-0px)" })
      }

      expect(stream.scrollTop).toBe(1300)
      expect(screen.queryByRole("button", { name: "2 new messages" })).not.toBeInTheDocument()
    } finally {
      restoreMedia()
      script.remove()
    }
  })

  it("keeps mobile workspace tabs stable off the Chat tab and reveals them when switching tabs", async () => {
    const restoreMedia = mockMediaQuery(false)
    const bootstrap = bootstrapPayload({
      current_user: {
        ...bootstrapPayload().current_user,
        mobile_chat_auto_hide_header: true
      }
    })
    const script = document.createElement("script")
    script.id = "syrus-bootstrap-data"
    script.type = "application/json"
    script.textContent = JSON.stringify(bootstrap)
    document.body.appendChild(script)
    vi.spyOn(window, "fetch").mockImplementation(async (input) => {
      const path = String(input)
      if (path.endsWith("/api/v1/app/bootstrap"))
        return new Response(JSON.stringify(bootstrap), { status: 200, headers: { "Content-Type": "application/json" } })

      return new Response(JSON.stringify(chatPayload()), { status: 200, headers: { "Content-Type": "application/json" } })
    })

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      const stream = await screen.findByTestId("chat-message-stream")
      const header = screen.getByTestId("mobile-app-header")
      const mobileTabs = screen.getByRole("navigation", { name: "Chat mobile tabs" })
      const mobileTabsShell = screen.getByTestId("mobile-chat-tabs-shell")

      for (const scrollTop of [200, 300, 400, 500, 600, 700]) {
        setScrollMetrics(stream, { scrollHeight: 1600, clientHeight: 400, scrollTop })
        fireEvent.touchMove(stream)
        fireEvent.scroll(stream, { target: { scrollTop } })
      }

      expect(header).toHaveStyle({ transform: "translateY(-142px)" })
      expect(mobileTabsShell).toHaveStyle({ transform: "translateY(-142px)" })

      fireEvent.click(within(mobileTabs).getByRole("button", { name: "Whiteboard" }))
      await waitFor(() => {
        expect(header).toHaveStyle({ transform: "translateY(-0px)" })
        expect(mobileTabsShell.getAttribute("style") ?? "").toBe("")
      })
      expect(within(mobileTabs).getByRole("button", { name: "Whiteboard" })).toHaveClass("border-brand")
      expect(await screen.findByRole("complementary", { name: "Chat workspace" })).toBeInTheDocument()
      expect(screen.queryByTestId("mobile-chat-hidden-header-sidebar-button")).not.toBeInTheDocument()

      fireEvent.click(within(mobileTabs).getByRole("button", { name: "Chat" }))
      const restoredStream = await screen.findByTestId("chat-message-stream")
      expect(mobileTabsShell).toHaveStyle({ transform: "translateY(-0px)" })

      for (const scrollTop of [500, 600, 700, 800, 900, 1000]) {
        setScrollMetrics(restoredStream, { scrollHeight: 1600, clientHeight: 400, scrollTop })
        fireEvent.touchMove(restoredStream)
        fireEvent.scroll(restoredStream, { target: { scrollTop } })
      }

      expect(header).toHaveStyle({ transform: "translateY(-142px)" })
      expect(mobileTabsShell).toHaveStyle({ transform: "translateY(-142px)" })
    } finally {
      restoreMedia()
      script.remove()
    }
  })

  it("truncates a long preview-panel tab title in the mobile tab strip instead of stretching it", async () => {
    const restoreMedia = mockMediaQuery(false)
    const longTitle = "A very long preview panel title that should never be allowed to stretch the tab strip or wrap onto a second line"
    vi.spyOn(window, "fetch").mockImplementation(
      async () =>
        new Response(
          JSON.stringify({
            ...chatPayload(),
            preview_panels: [
              {
                id: 1,
                title: longTitle,
                file_count: 2,
                url: "http://127.0.0.1:3001",
                visibility: "public",
                app_close_path: "/api/v1/app/chats/8/preview_panels/1",
                app_visibility_path: "/api/v1/app/chats/8/preview_panels/1",
                app_export_path: "/api/v1/app/chats/8/preview_panels/1/export",
                app_file_base_path: "/api/v1/app/chats/8/preview_panels/1/files",
                app_token_path: "/api/v1/app/chats/8/preview_panels/1/token",
                current_version_id: null,
                entry_path: "index.html",
                entry_content_type: "text/html",
                entry_viewer_kind: "html",
                versions: []
              }
            ]
          }),
          { status: 200, headers: { "Content-Type": "application/json" } }
        )
    )

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      const mobileTabs = await screen.findByRole("navigation", { name: "Chat mobile tabs" })
      const previewTabButton = within(mobileTabs).getByRole("button", { name: longTitle })
      expect(previewTabButton).toHaveClass("max-w-[33vw]", "truncate", "shrink-0")
    } finally {
      restoreMedia()
    }
  })

  it("renders low chat token totals without rounding them down to 0k", async () => {
    vi.spyOn(window, "fetch").mockImplementation(
      async () =>
        new Response(
          JSON.stringify(
            chatPayload({
              cumulativeInputTokens: 12,
              cumulativeOutputTokens: 5,
              cumulativeCostUsd: 0.004321
            })
          ),
          { status: 200, headers: { "Content-Type": "application/json" } }
        )
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByText("Tokens: 12 in / 5 out · $0.0043")).toBeInTheDocument()
  })

  it("resizes the chat shell from the visual viewport when the mobile keyboard opens", async () => {
    const restoreHeight = setViewportHeight(820)
    const viewport = stubVisualViewport(680)
    vi.spyOn(window, "fetch").mockImplementation(
      async () => new Response(JSON.stringify(chatPayload()), { status: 200, headers: { "Content-Type": "application/json" } })
    )

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      const chatMain = await screen.findByRole("main", { name: "Chat" })
      expect(chatMain).toHaveStyle({ "--chat-visual-viewport-height": "680px" })

      viewport.setHeight(420)
      viewport.dispatch("resize")

      await waitFor(() => {
        expect(chatMain).toHaveStyle({ "--chat-visual-viewport-height": "420px" })
      })
    } finally {
      restoreHeight()
      viewport.restore()
    }
  })

  it("tracks the root visual viewport while the mobile keyboard is open", async () => {
    const restoreMedia = mockMediaQuery(false)
    const restoreHeight = setViewportHeight(812)
    const viewport = stubVisualViewport({ height: 602, width: 375 })
    vi.spyOn(window, "fetch").mockImplementation(
      async () => new Response(JSON.stringify(chatPayload()), { status: 200, headers: { "Content-Type": "application/json" } })
    )

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      const chromeRoot = await screen.findByTestId("app-chrome-root")
      expect(chromeRoot).toHaveClass("h-[var(--syrus-app-viewport-height,100dvh)]", "overflow-hidden")
      expect(chromeRoot).toHaveStyle({ "--syrus-app-viewport-height": "602px", "--syrus-app-viewport-width": "375px" })

      viewport.setMetrics({ height: 402, width: 750, offsetTop: 48, offsetLeft: 7 })
      window.dispatchEvent(new Event("orientationchange"))

      await waitFor(() => {
        expect(chromeRoot).toHaveStyle({
          "--syrus-app-viewport-height": "402px",
          "--syrus-app-viewport-offset-left": "7px",
          "--syrus-app-viewport-offset-top": "48px",
          "--syrus-app-viewport-width": "750px",
          left: "var(--syrus-app-viewport-offset-left,0px)",
          position: "fixed",
          top: "var(--syrus-app-viewport-offset-top,0px)",
          width: "var(--syrus-app-viewport-width,100vw)"
        })
      })
      expect(document.documentElement.style.getPropertyValue("--syrus-app-viewport-height")).toBe("402px")
      expect(document.documentElement.style.getPropertyValue("--syrus-app-viewport-offset-top")).toBe("48px")
    } finally {
      restoreMedia()
      restoreHeight()
      viewport.restore()
    }
  })

  it("ignores rubber-band offsets and removes keyboard viewport styles when the viewport expands", async () => {
    const restoreMedia = mockMediaQuery(false)
    const restoreHeight = setViewportHeight(812)
    const viewport = stubVisualViewport({ height: 602, offsetLeft: 3, offsetTop: 24, width: 375 })

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/dashboard"]}>
            <AppChromeV2 initialBootstrap={bootstrapPayload() as unknown as BootstrapPayload}>
              <main>Dashboard content</main>
            </AppChromeV2>
          </MemoryRouter>
        </QueryClientProvider>
      )

      const chromeRoot = await screen.findByTestId("app-chrome-root")
      expect(chromeRoot).toHaveStyle({
        "--syrus-app-viewport-height": "602px",
        position: "fixed"
      })

      viewport.setMetrics({ height: 800, offsetTop: 12 })
      viewport.dispatch("scroll")

      await waitFor(() => expect(chromeRoot).not.toHaveStyle({ position: "fixed" }))
      expect(chromeRoot).toHaveClass("h-[var(--syrus-app-viewport-height,100dvh)]")
      expect(document.documentElement.style.getPropertyValue("--syrus-app-viewport-height")).toBe("")
      expect(document.documentElement.style.getPropertyValue("--syrus-app-viewport-offset-top")).toBe("")
      expect(screen.getByText("Dashboard content")).toBeInTheDocument()
    } finally {
      restoreMedia()
      restoreHeight()
      viewport.restore()
    }
  })

  it("does not resize or reposition the app chrome while pinch zoomed", async () => {
    const restoreMedia = mockMediaQuery(false)
    const restoreHeight = setViewportHeight(812)
    const viewport = stubVisualViewport({ height: 402, offsetLeft: 7, offsetTop: 48, scale: 2, width: 188 })

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/dashboard"]}>
            <AppChromeV2 initialBootstrap={bootstrapPayload() as unknown as BootstrapPayload}>
              <main>Dashboard content</main>
            </AppChromeV2>
          </MemoryRouter>
        </QueryClientProvider>
      )

      const chromeRoot = await screen.findByTestId("app-chrome-root")
      expect(chromeRoot).not.toHaveStyle({ position: "fixed" })
      expect(document.documentElement.style.getPropertyValue("--syrus-app-viewport-height")).toBe("")
    } finally {
      restoreMedia()
      restoreHeight()
      viewport.restore()
    }
  })
})
