import { jsonResponse } from "@app/testSupport"
import { fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { beforeEach, describe, expect, it, vi } from "vitest"
import { MemoryRouter } from "react-router-dom"
import type { ReactElement } from "react"
import { AppChromeV2 } from "@app/routes/AppChromeV2"
import { TerminalPane, TerminalRoute } from "./Terminal"
import type { BootstrapPayload } from "@app/api/bootstrap"
import type { TerminalSessionRecord, TerminalSessionsPayload } from "../api/terminal"

const actionCable = vi.hoisted(() => ({
  createSubscription: vi.fn(() => ({ perform: vi.fn(), unsubscribe: vi.fn() }))
}))

const xtermMock = vi.hoisted(() => ({
  terminalConstructor: vi.fn(),
  open: vi.fn(),
  write: vi.fn(),
  dispose: vi.fn(),
  onData: vi.fn(),
  onResize: vi.fn(),
  loadAddon: vi.fn(),
  fit: vi.fn()
}))

vi.mock("@rails/actioncable", () => ({
  createConsumer: () => ({
    subscriptions: {
      create: actionCable.createSubscription
    }
  })
}))

vi.mock("xterm", () => ({
  Terminal: class {
    cols = 132
    element: HTMLElement | null = null
    rows = 43

    constructor(options: unknown) {
      xtermMock.terminalConstructor(options)
    }

    loadAddon(addon: unknown) {
      xtermMock.loadAddon(addon)
    }

    open(element: HTMLElement) {
      this.element = element
      xtermMock.open(element)
    }

    write(data: string | Uint8Array) {
      xtermMock.write(data)
      if (this.element) {
        const text = typeof data === "string" ? data : new TextDecoder().decode(data)
        this.element.append(document.createTextNode(text))
      }
    }

    onData(callback: (data: string) => void) {
      xtermMock.onData(callback)
      return { dispose: vi.fn() }
    }

    onResize(callback: (size: { cols: number; rows: number }) => void) {
      xtermMock.onResize(callback)
      return { dispose: vi.fn() }
    }

    dispose() {
      xtermMock.dispose()
    }
  }
}))

vi.mock("@xterm/addon-fit", () => ({
  FitAddon: class {
    fit() {
      xtermMock.fit()
    }
  }
}))

describe("TerminalRoute", () => {
  let rectSpy: ReturnType<typeof vi.spyOn> | undefined

  beforeEach(() => {
    rectSpy?.mockRestore()
    rectSpy = vi.spyOn(HTMLElement.prototype, "getBoundingClientRect").mockReturnValue({
      bottom: 400,
      height: 400,
      left: 0,
      right: 800,
      top: 0,
      width: 800,
      x: 0,
      y: 0,
      toJSON: () => ({})
    })
    actionCable.createSubscription.mockClear()
    xtermMock.terminalConstructor.mockClear()
    xtermMock.open.mockClear()
    xtermMock.write.mockClear()
    xtermMock.dispose.mockClear()
    xtermMock.onData.mockClear()
    xtermMock.onResize.mockClear()
    xtermMock.loadAddon.mockClear()
    xtermMock.fit.mockClear()
  })

  it("renders session tabs and activates the session from the URL", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(terminalSessionsPayload()))

    renderTerminalRoute("/terminal?session=2")

    await screen.findByRole("tab", { name: "Deploy shell" })
    const tablist = screen.getByRole("tablist", { name: "Terminal sessions" })
    expect(within(tablist).getByRole("tab", { name: "Deploy shell" })).toHaveAttribute("aria-selected", "true")
    expect(within(tablist).getByRole("tab", { name: "Scratch" })).toBeInTheDocument()
    expect(screen.getByText("/syrus-home/.syrus/workflows/99")).toBeInTheDocument()
  })

  it("creates a session from the workspace picker", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/terminal_sessions" && init?.method === "POST") {
        return Promise.resolve(jsonResponse({ session: terminalSession({ id: 3, name: "WF-100 - Follow-up" }) }, 201))
      }

      return Promise.resolve(jsonResponse(terminalSessionsPayload()))
    })

    renderTerminalRoute()

    fireEvent.click(await screen.findByRole("button", { name: "+" }))
    fireEvent.click(screen.getByRole("menuitem", { name: /WF-99 - Build terminal/ }))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/terminal_sessions",
        expect.objectContaining({
          method: "POST",
          body: expect.stringContaining("\"candidate_key\":\"workflow:99\"")
        })
      )
    })
    expect(await screen.findByRole("tab", { name: "WF-100 - Follow-up" })).toBeInTheDocument()
  })

  it("groups the default workspace picker and limits each section to three choices", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(terminalSessionsPayload({
      workspaces: [
        workspace({ key: "workflow:1", id: 1, label: "WF-1 - Failed checkout", section: "interesting_workflows", section_title: "Interesting workflows" }),
        workspace({ key: "workflow:2", id: 2, label: "WF-2 - Running checkout", section: "interesting_workflows", section_title: "Interesting workflows" }),
        workspace({ key: "workflow:3", id: 3, label: "WF-3 - Approved checkout", section: "interesting_workflows", section_title: "Interesting workflows" }),
        workspace({ key: "workflow:4", id: 4, label: "WF-4 - Search-only checkout", section: "interesting_workflows", section_title: "Interesting workflows", search_text: "needle workflow" }),
        workspace({ key: "workflow:5", id: 5, label: "WF-5 - Stale succeeded checkout", section: "interesting_workflows", section_title: "Interesting workflows", default_visible: false, search_text: "stale-only workflow" }),
        workspace({ key: "chat:10", id: 10, label: "Chat #10 - Coding terminal", kind: "chat", section: "coding_chats", section_title: "Coding chats" }),
        workspace({ key: "worker:alpha:storage-a", id: "worker:alpha:storage-a", label: "Scratch on alpha", kind: "worker", section: "workers", section_title: "Workers", worker_hostname: "alpha", worker_storage_key: "storage-a" })
      ]
    })))

    renderTerminalRoute()

    fireEvent.click(await screen.findByRole("button", { name: "+" }))

    expect(screen.getByText("Interesting workflows")).toBeInTheDocument()
    expect(screen.getByText("Coding chats")).toBeInTheDocument()
    expect(screen.getByText("Workers")).toBeInTheDocument()
    expect(screen.getByRole("menuitem", { name: /WF-1 - Failed checkout/ })).toBeInTheDocument()
    expect(screen.queryByRole("menuitem", { name: /WF-4 - Search-only checkout/ })).not.toBeInTheDocument()
    expect(screen.queryByRole("menuitem", { name: /WF-5 - Stale succeeded checkout/ })).not.toBeInTheDocument()
  })

  it("searches workspace candidates across hidden default entries and worker metadata", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(terminalSessionsPayload({
      workspaces: [
        workspace({ key: "workflow:1", id: 1, label: "WF-1 - Failed checkout", section: "interesting_workflows", section_title: "Interesting workflows" }),
        workspace({ key: "workflow:2", id: 2, label: "WF-2 - Running checkout", section: "interesting_workflows", section_title: "Interesting workflows" }),
        workspace({ key: "workflow:3", id: 3, label: "WF-3 - Approved checkout", section: "interesting_workflows", section_title: "Interesting workflows" }),
        workspace({ key: "workflow:4", id: 4, label: "WF-4 - Search-only checkout", section: "interesting_workflows", section_title: "Interesting workflows", search_text: "needle workflow" }),
        workspace({ key: "worker:beta:storage-b", id: "worker:beta:storage-b", label: "Scratch on beta", kind: "worker", section: "workers", section_title: "Workers", worker_hostname: "beta", worker_storage_key: "storage-b", search_text: "beta storage-b" })
      ]
    })))

    renderTerminalRoute()

    fireEvent.click(await screen.findByRole("button", { name: "+" }))
    fireEvent.change(screen.getByRole("searchbox", { name: "Search workspaces" }), { target: { value: "storage-b" } })

    expect(screen.getByRole("menuitem", { name: /Scratch on beta/ })).toBeInTheDocument()
    expect(screen.queryByRole("menuitem", { name: /WF-1 - Failed checkout/ })).not.toBeInTheDocument()
  })

  it("can find stale workflow candidates through search without showing them by default", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(terminalSessionsPayload({
      workspaces: [
        workspace({ key: "workflow:5", id: 5, label: "WF-5 - Stale succeeded checkout", section: "interesting_workflows", section_title: "Interesting workflows", default_visible: false, search_text: "stale-only workflow" })
      ]
    })))

    renderTerminalRoute()

    fireEvent.click(await screen.findByRole("button", { name: "+" }))
    expect(screen.queryByRole("menuitem", { name: /WF-5 - Stale succeeded checkout/ })).not.toBeInTheDocument()

    fireEvent.change(screen.getByRole("searchbox", { name: "Search workspaces" }), { target: { value: "stale-only" } })
    expect(screen.getByRole("menuitem", { name: /WF-5 - Stale succeeded checkout/ })).toBeInTheDocument()
  })

  it("kills a session from its tab close button", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/terminal_sessions/1" && init?.method === "DELETE") {
        return Promise.resolve(jsonResponse({ session: terminalSession({ id: 1, name: "Scratch", finished_at: "2026-06-27T12:05:00Z", outcome: "killed" }) }))
      }

      return Promise.resolve(jsonResponse(terminalSessionsPayload()))
    })

    renderTerminalRoute()

    fireEvent.click(await screen.findByRole("button", { name: "Close Scratch" }))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/terminal_sessions/1", expect.objectContaining({ method: "DELETE" }))
    })
    await waitFor(() => {
      expect(screen.queryByRole("tab", { name: "Scratch" })).not.toBeInTheDocument()
    })
  })

  it("subscribes TerminalPane to the TerminalChannel and shows the disconnected overlay", async () => {
    const subscription = { perform: vi.fn(), unsubscribe: vi.fn() }
    actionCable.createSubscription.mockReturnValue(subscription)

    renderWithClient(
      <MemoryRouter>
        <TerminalPane session={terminalSession({ id: 4 })} />
      </MemoryRouter>
    )

    await waitFor(() => {
      expect(actionCable.createSubscription).toHaveBeenCalledWith(
        { channel: "TerminalChannel", session_id: 4 },
        expect.objectContaining({ connected: expect.any(Function), received: expect.any(Function) })
      )
    })
    const mixin = (actionCable.createSubscription.mock.calls[0] as unknown as [
      unknown,
      { connected(): void; received(data: { type: string; data?: string }): void }
    ])[1]
    mixin.connected()
    expect(subscription.perform).toHaveBeenCalledWith("receive", { type: "resize", cols: 132, rows: 43 })

    mixin.received({ type: "output", data: btoa("hello") })
    expect(xtermMock.write).toHaveBeenCalledWith(Uint8Array.from([104, 101, 108, 108, 111]))

    const onData = xtermMock.onData.mock.calls[0][0] as (data: string) => void
    onData("ls\n")
    expect(subscription.perform).toHaveBeenCalledWith("receive", { type: "input", data: "ls\n" })

    const onResize = xtermMock.onResize.mock.calls[0][0] as (size: { cols: number; rows: number }) => void
    onResize({ cols: 120, rows: 40 })
    expect(subscription.perform).toHaveBeenCalledWith("receive", { type: "resize", cols: 120, rows: 40 })

    mixin.received({ type: "disconnected" })
    expect(await screen.findByText("Session ended - reload to reconnect")).toBeInTheDocument()
    expect(screen.getByText("○ disconnected")).toBeInTheDocument()
  })

  it("opens and fits TerminalPane only after the pane has measurable dimensions", async () => {
    rectSpy?.mockReturnValue({
      bottom: 0,
      height: 0,
      left: 0,
      right: 0,
      top: 0,
      width: 0,
      x: 0,
      y: 0,
      toJSON: () => ({})
    })

    renderWithClient(
      <MemoryRouter>
        <TerminalPane session={terminalSession({ id: 6 })} />
      </MemoryRouter>
    )

    expect(xtermMock.open).not.toHaveBeenCalled()
    expect(xtermMock.fit).not.toHaveBeenCalled()

    rectSpy?.mockReturnValue({
      bottom: 400,
      height: 400,
      left: 0,
      right: 800,
      top: 0,
      width: 800,
      x: 0,
      y: 0,
      toJSON: () => ({})
    })

    window.dispatchEvent(new Event("resize"))
    await waitFor(() => expect(xtermMock.open).toHaveBeenCalled())
    expect(xtermMock.fit).toHaveBeenCalled()
  })

  it("writes replay frames to the terminal before live output", async () => {
    const subscription = { perform: vi.fn(), unsubscribe: vi.fn() }
    actionCable.createSubscription.mockReturnValue(subscription)

    renderWithClient(
      <MemoryRouter>
        <TerminalPane session={terminalSession({ id: 5 })} />
      </MemoryRouter>
    )
    await waitFor(() => expect(actionCable.createSubscription).toHaveBeenCalled())
    const mixin = (actionCable.createSubscription.mock.calls[0] as unknown as [unknown, { received(data: { type: string; data?: string }): void }])[1]

    mixin.received({ type: "replay", data: btoa("scrollback history") })
    expect(xtermMock.write).toHaveBeenCalledWith(Uint8Array.from(Array.from("scrollback history", (c) => c.charCodeAt(0))))

    mixin.received({ type: "output", data: btoa("live output") })
    expect(xtermMock.write).toHaveBeenCalledWith(Uint8Array.from(Array.from("live output", (c) => c.charCodeAt(0))))
  })

  // Terminal reaches the sidebar as a sidebar_page now, and its badge through
  // the generic badge_api_path the chrome polls -- core no longer knows what
  // is being counted.
  const sidebarPage = {
    id: "terminal",
    label: "Terminal",
    path: "/terminal",
    paths: [ "/terminal" ],
    order: 40,
    icon: "terminal",
    badge_api_path: "/api/v1/app/terminal_sessions/open_count"
  }

  it("renders the sidebar Terminal item and its live badge", async () => {
    vi.spyOn(window, "fetch").mockImplementation((input) => {
      const path = String(input)
      if (path.startsWith("/api/v1/app/sidebar_pages")) return Promise.resolve(jsonResponse({ pages: [ sidebarPage ] }))
      if (path.startsWith("/api/v1/app/terminal_sessions/open_count")) return Promise.resolve(jsonResponse({ count: 2 }))
      if (path.startsWith("/api/v1/app/chats")) return Promise.resolve(jsonResponse({ groups: [], chats: [], pagination: { total: 0 } }))
      return Promise.resolve(jsonResponse(bootstrapPayload({ feature_flags: { v2_ui: true } })))
    })

    renderWithClient(
      <MemoryRouter initialEntries={["/app-shell/repositories"]}>
        <AppChromeV2 initialBootstrap={bootstrapPayload({ feature_flags: { v2_ui: true } })}>
          <main>Dashboard</main>
        </AppChromeV2>
      </MemoryRouter>
    )

    const primaryNav = await screen.findByRole("navigation", { name: "Primary" })
    expect(await within(primaryNav).findByRole("link", { name: /Terminal/ })).toHaveAttribute("href", "/app-shell/terminal")
    expect(await within(primaryNav).findByText("2")).toBeInTheDocument()
  })

  it("hides the sidebar Terminal badge when there are no running sessions", async () => {
    vi.spyOn(window, "fetch").mockImplementation((input) => {
      const path = String(input)
      if (path.startsWith("/api/v1/app/sidebar_pages")) return Promise.resolve(jsonResponse({ pages: [ sidebarPage ] }))
      if (path.startsWith("/api/v1/app/terminal_sessions/open_count")) return Promise.resolve(jsonResponse({ count: 0 }))
      if (path.startsWith("/api/v1/app/chats")) return Promise.resolve(jsonResponse({ groups: [], chats: [], pagination: { total: 0 } }))
      return Promise.resolve(jsonResponse(bootstrapPayload({ feature_flags: { v2_ui: true } })))
    })

    renderWithClient(
      <MemoryRouter initialEntries={["/app-shell/repositories"]}>
        <AppChromeV2 initialBootstrap={bootstrapPayload({ feature_flags: { v2_ui: true } })}>
          <main>Dashboard</main>
        </AppChromeV2>
      </MemoryRouter>
    )

    const primaryNav = await screen.findByRole("navigation", { name: "Primary" })
    expect(await within(primaryNav).findByRole("link", { name: "Terminal" })).toBeInTheDocument()
    expect(within(primaryNav).queryByText("0")).not.toBeInTheDocument()
  })
})

function renderTerminalRoute(path = "/terminal") {
  return renderWithClient(
    <MemoryRouter initialEntries={[path]}>
      <TerminalRoute />
    </MemoryRouter>
  )
}

function renderWithClient(ui: ReactElement, bootstrap?: BootstrapPayload) {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  if (bootstrap) queryClient.setQueryData(["bootstrap"], bootstrap)

  return render(
    <QueryClientProvider client={queryClient}>
      {ui}
    </QueryClientProvider>
  )
}

function terminalSessionsPayload(overrides: Partial<TerminalSessionsPayload> = {}): TerminalSessionsPayload {
  return {
    sessions: [
      terminalSession({ id: 1, name: "Scratch", working_directory: "/app" }),
      terminalSession({ id: 2, name: "Deploy shell", working_directory: "/syrus-home/.syrus/workflows/99" })
    ],
    workspaces: [
      workspace({ key: "worker:local", id: "worker:local", label: "Scratch on local", working_directory: "/app", kind: "worker", section: "workers", section_title: "Workers" }),
      workspace({ key: "workflow:99", id: 99, label: "WF-99 - Build terminal", working_directory: "/syrus-home/.syrus/workflows/99", kind: "workflow", section: "interesting_workflows", section_title: "Interesting workflows", workflow_id: 99 })
    ],
    ...overrides
  }
}

function workspace(overrides: Partial<TerminalSessionsPayload["workspaces"][number]> = {}): TerminalSessionsPayload["workspaces"][number] {
  return {
    key: "workflow:99",
    id: 99,
    label: "WF-99 - Build terminal",
    secondary_text: "acme/widgets · JOB-99 · failed",
    working_directory: "/syrus-home/.syrus/workflows/99",
    kind: "workflow",
    section: "interesting_workflows",
    section_title: "Interesting workflows",
    actionability: "needs attention",
    workflow_id: 99,
    default_visible: true,
    search_text: "wf-99 build terminal acme widgets",
    ...overrides
  }
}

function terminalSession(overrides: Partial<TerminalSessionRecord> = {}): TerminalSessionRecord {
  return {
    id: 1,
    name: "Scratch",
    working_directory: "/app",
    started_at: "2026-06-27T12:00:00Z",
    finished_at: null,
    outcome: null,
    workflow_id: null,
    chat_session_id: null,
    worker_hostname: null,
    worker_storage_key: null,
    queue_name: null,
    workspace_kind: null,
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
      role: "developer",
      scheduling_paused: false,
      landing_paused: false,
      agent_provider: "claude",
      chat_provider: null,
      agent_max_turns: 200,
      theme: "light",
      locale: "en",
    gemini_configured: false
    },
    team_user_count: 1,
    app: { revision: "dev", revision_url: null, version: null, built_at: null, bug_report_mode: null, report_issue_repo_slug: "tkadauke/syrus", mode: "advanced" as const, mode_configured: false, legacy_epics_visible: false },
    public: {
      first_signup: false,
      signups_open: false,
      signup_path: "/users/new",
      sign_in_path: "/session/new",
      docs_url: "https://syrus.dev/docs/getting-started",
      evaluation_url: "https://syrus.dev/docs/deployment/docker-compose"
    },
    navigation: { default_chat_path: "/dashboard" },
    setup: null,
    setup_status: null,
    csrf_token: "csrf-token",
    unread_notifications_count: 0,
    feature_flags: {},
    ...overrides
  }
}
