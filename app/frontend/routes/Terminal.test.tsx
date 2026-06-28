import { fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { beforeEach, describe, expect, it, vi } from "vitest"
import { MemoryRouter } from "react-router-dom"
import type { ReactElement } from "react"
import { AppChromeV2 } from "./AppChromeV2"
import { TerminalPane, TerminalRoute } from "./Terminal"
import type { BootstrapPayload } from "../api/bootstrap"
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
    constructor(options: unknown) {
      xtermMock.terminalConstructor(options)
    }

    loadAddon(addon: unknown) {
      xtermMock.loadAddon(addon)
    }

    open(element: HTMLElement) {
      xtermMock.open(element)
    }

    write(data: Uint8Array) {
      xtermMock.write(data)
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
  beforeEach(() => {
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
        return Promise.resolve(jsonResponse({ session: terminalSession({ id: 3, name: "WF-100 - Follow-up" }) }, { status: 201 }))
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
          body: expect.stringContaining("\"workflow_id\":99")
        })
      )
    })
    expect(await screen.findByRole("tab", { name: "WF-100 - Follow-up" })).toBeInTheDocument()
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

  it("does not fetch sessions when the terminal feature is disabled", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(terminalSessionsPayload()))

    renderTerminalRoute("/terminal", bootstrapPayload({ feature_flags: { terminal: false, v2_ui: true } }))

    await waitFor(() => {
      expect(fetchSpy).not.toHaveBeenCalled()
    })
    expect(screen.getByText("No terminal sessions")).toBeInTheDocument()
  })

  it("subscribes TerminalPane to the TerminalChannel and shows the disconnected overlay", async () => {
    const subscription = { perform: vi.fn(), unsubscribe: vi.fn() }
    actionCable.createSubscription.mockReturnValue(subscription)

    renderWithClient(
      <MemoryRouter>
        <TerminalPane session={terminalSession({ id: 4 })} />
      </MemoryRouter>
    )

    expect(actionCable.createSubscription).toHaveBeenCalledWith(
      { channel: "TerminalChannel", session_id: 4 },
      expect.objectContaining({ received: expect.any(Function) })
    )
    const mixin = (actionCable.createSubscription.mock.calls[0] as unknown as [unknown, { received(data: { type: string; data?: string }): void }])[1]
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

  it("renders the sidebar Terminal item and live badge when the feature is enabled", async () => {
    vi.spyOn(window, "fetch").mockImplementation((input) => {
      const path = String(input)
      if (path === "/api/v1/app/terminal_sessions") return Promise.resolve(jsonResponse(terminalSessionsPayload()))
      if (path.startsWith("/api/v1/app/chats")) return Promise.resolve(jsonResponse({ groups: [], chats: [], pagination: { total: 0 } }))
      return Promise.resolve(jsonResponse(bootstrapPayload({ feature_flags: { terminal: true, v2_ui: true } })))
    })

    renderWithClient(
      <MemoryRouter initialEntries={["/app-shell/repositories"]}>
        <AppChromeV2 initialBootstrap={bootstrapPayload({ feature_flags: { terminal: true, v2_ui: true } })}>
          <main>Dashboard</main>
        </AppChromeV2>
      </MemoryRouter>
    )

    const primaryNav = await screen.findByRole("navigation", { name: "Primary" })
    expect(within(primaryNav).getByRole("link", { name: /Terminal/ })).toHaveAttribute("href", "/app-shell/terminal")
    expect(await within(primaryNav).findByText("2")).toBeInTheDocument()
  })

  it("hides the sidebar Terminal badge when there are no running sessions", async () => {
    vi.spyOn(window, "fetch").mockImplementation((input) => {
      const path = String(input)
      if (path === "/api/v1/app/terminal_sessions") return Promise.resolve(jsonResponse(terminalSessionsPayload({ sessions: [] })))
      if (path.startsWith("/api/v1/app/chats")) return Promise.resolve(jsonResponse({ groups: [], chats: [], pagination: { total: 0 } }))
      return Promise.resolve(jsonResponse(bootstrapPayload({ feature_flags: { terminal: true, v2_ui: true } })))
    })

    renderWithClient(
      <MemoryRouter initialEntries={["/app-shell/repositories"]}>
        <AppChromeV2 initialBootstrap={bootstrapPayload({ feature_flags: { terminal: true, v2_ui: true } })}>
          <main>Dashboard</main>
        </AppChromeV2>
      </MemoryRouter>
    )

    const primaryNav = await screen.findByRole("navigation", { name: "Primary" })
    expect(within(primaryNav).getByRole("link", { name: "Terminal" })).toBeInTheDocument()
    expect(within(primaryNav).queryByText("0")).not.toBeInTheDocument()
  })
})

function renderTerminalRoute(path = "/terminal", bootstrap = bootstrapPayload({ feature_flags: { terminal: true, v2_ui: true } })) {
  return renderWithClient(
    <MemoryRouter initialEntries={[path]}>
      <TerminalRoute />
    </MemoryRouter>,
    bootstrap
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
      { id: null, label: "Scratch", working_directory: "/app", kind: "scratch" },
      { id: 99, label: "WF-99 - Build terminal", working_directory: "/syrus-home/.syrus/workflows/99", kind: "workflow" }
    ],
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
    setup: null,
    setup_status: null,
    csrf_token: "csrf-token",
    unread_notifications_count: 0,
    feature_flags: {},
    ...overrides
  }
}

function jsonResponse(payload: unknown, options: { status?: number } = {}) {
  return new Response(JSON.stringify(payload), {
    status: options.status ?? 200,
    headers: { "Content-Type": "application/json" }
  })
}
