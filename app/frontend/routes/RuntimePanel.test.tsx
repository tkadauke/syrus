import { jsonResponse } from "../testSupport"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { act, fireEvent, render, screen, waitFor } from "@testing-library/react"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import { RuntimePanel } from "./RuntimePanel"
import type { RuntimeControlLease, RuntimeSession } from "../api/chats"

const actionCable = vi.hoisted(() => ({
  createSubscription: vi.fn(() => ({ perform: vi.fn(), unsubscribe: vi.fn() }))
}))

const xtermMock = vi.hoisted(() => ({
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

beforeEach(() => {
  vi.spyOn(HTMLElement.prototype, "getBoundingClientRect").mockReturnValue({
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
  xtermMock.open.mockClear()
  xtermMock.write.mockClear()
  xtermMock.dispose.mockClear()
  xtermMock.onData.mockClear()
  xtermMock.onResize.mockClear()
  xtermMock.loadAddon.mockClear()
  xtermMock.fit.mockClear()
})

afterEach(() => {
  vi.useRealTimers()
  vi.restoreAllMocks()
})

function terminalSessionFixture(overrides: Partial<RuntimeSession> = {}): RuntimeSession {
  return sessionFixture({
    provider_key: "cli_tui",
    display_name: "Terminal",
    capabilities: { input: ["keyboard", "stdin", "resize"] },
    metadata: { terminal_session_id: 404 },
    ...overrides
  })
}

function sessionFixture(overrides: Partial<RuntimeSession> = {}): RuntimeSession {
  return {
    id: 101,
    provider_key: "browser",
    display_name: "Browser",
    state: "running",
    primary: true,
    workspace_ref: "/workspaces/26148",
    capabilities: {},
    metadata: { port: 3001, url: "http://127.0.0.1:3001" },
    stream_url: null,
    latest_frame_url: null,
    latest_frame_at: null,
    last_error: null,
    active_agent_input_lease: null,
    ...overrides
  }
}

function agentLease(overrides: Partial<RuntimeControlLease> = {}): RuntimeControlLease {
  return {
    id: 5,
    owner: "agent",
    owner_ref: "coding_mode_chat:8",
    mode: "input",
    reason: "typing",
    state: "active",
    acquired_at: "2026-01-01T00:00:00Z",
    expires_at: "2026-01-01T00:00:30Z",
    cancellable: true,
    ...overrides
  }
}

function renderPanel(client = new QueryClient({ defaultOptions: { queries: { retry: false } } })) {
  render(
    <QueryClientProvider client={client}>
      <RuntimePanel chatId={8} />
    </QueryClientProvider>
  )
  return client
}

function mockFetch(handler: (url: string, method: string) => Response | Promise<Response>) {
  vi.spyOn(window, "fetch").mockImplementation((input, init) => {
    const url = typeof input === "string" ? input : input.toString()
    const method = (init?.method || "GET").toUpperCase()
    return Promise.resolve(handler(url, method))
  })
}

describe("RuntimePanel empty/loading/error states", () => {
  it("shows the empty state when there are no runtime sessions", async () => {
    mockFetch(() => jsonResponse({ runtime_sessions: [] }))

    renderPanel()

    expect(await screen.findByText("No runtime sessions yet.")).toBeInTheDocument()
  })

  it("shows an error message when the sessions request fails", async () => {
    mockFetch(() => jsonResponse({ error: { code: "server_error", message: "boom" } }, 500))

    renderPanel()

    expect(await screen.findByText("Could not load runtime sessions.")).toBeInTheDocument()
  })
})

describe("RuntimePanel session detail", () => {
  it("renders the session state, provider metadata, and empty logs", async () => {
    mockFetch((url) => {
      if (url.includes("/logs")) return jsonResponse({ entries: [], cursor: 0 })
      return jsonResponse({ runtime_sessions: [sessionFixture()] })
    })

    renderPanel()

    expect(await screen.findByText("Browser")).toBeInTheDocument()
    expect(screen.getByText("running")).toBeInTheDocument()
    expect(screen.getByText("browser")).toBeInTheDocument()
    expect(screen.getByText("/workspaces/26148")).toBeInTheDocument()
    expect(screen.getByText("No log output yet.")).toBeInTheDocument()
    expect(screen.getByText("No screenshot captured yet.")).toBeInTheDocument()
  })

  it("shows the latest screenshot when latest_frame_url is present", async () => {
    mockFetch((url) => {
      if (url.includes("/logs")) return jsonResponse({ entries: [], cursor: 0 })
      return jsonResponse({
        runtime_sessions: [sessionFixture({ latest_frame_url: "/api/v1/app/chats/8/runtime_sessions/101/frame", latest_frame_at: "2026-01-01T00:00:00Z" })]
      })
    })

    renderPanel()

    const image = await screen.findByAltText("Latest screenshot")
    expect(image).toHaveAttribute("src", "/api/v1/app/chats/8/runtime_sessions/101/frame")
  })

  it("polls and appends new log lines using the returned cursor", async () => {
    let logCalls = 0
    mockFetch((url) => {
      if (url.includes("/logs")) {
        logCalls += 1
        const cursor = new URL(url, "http://localhost").searchParams.get("cursor")
        if (cursor === "0" || cursor === null) return jsonResponse({ entries: ["line-1"], cursor: 1 })
        return jsonResponse({ entries: [], cursor: 1 })
      }
      return jsonResponse({ runtime_sessions: [sessionFixture()] })
    })

    renderPanel()

    expect(await screen.findByText("line-1")).toBeInTheDocument()
    expect(logCalls).toBeGreaterThan(0)
  })
})

describe("RuntimePanel capture action", () => {
  it("captures a screenshot, refreshes the session in place, and invalidates chat media", async () => {
    mockFetch((url, method) => {
      if (url.includes("/logs")) return jsonResponse({ entries: [], cursor: 0 })
      if (url.includes("/capture") && method === "POST") {
        return jsonResponse({
          runtime_session: sessionFixture({ latest_frame_url: "/api/v1/app/chats/8/runtime_sessions/101/frame", latest_frame_at: "2026-01-01T00:05:00Z" })
        })
      }
      return jsonResponse({ runtime_sessions: [sessionFixture()] })
    })

    const client = renderPanel()
    const invalidateQueries = vi.spyOn(client, "invalidateQueries")

    await screen.findByText("No screenshot captured yet.")
    fireEvent.click(screen.getByRole("button", { name: "Capture" }))

    expect(await screen.findByAltText("Latest screenshot")).toBeInTheDocument()
    expect(invalidateQueries).toHaveBeenCalledWith({ queryKey: ["chat_media", "8"] })
  })
})

describe("RuntimePanel terminal live view", () => {
  it("subscribes terminal runtime sessions to TerminalChannel and renders live output", async () => {
    const subscription = { perform: vi.fn(), unsubscribe: vi.fn() }
    actionCable.createSubscription.mockReturnValue(subscription)
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input) => {
      const url = String(input)
      if (url.includes("/logs")) return Promise.resolve(jsonResponse({ entries: ["should-not-poll"], cursor: 1 }))
      return Promise.resolve(jsonResponse({ runtime_sessions: [terminalSessionFixture()] }))
    })

    renderPanel()

    expect(await screen.findByText("Live terminal")).toBeInTheDocument()
    await waitFor(() => {
      expect(actionCable.createSubscription).toHaveBeenCalledWith(
        { channel: "TerminalChannel", session_id: 404 },
        expect.objectContaining({ connected: expect.any(Function), received: expect.any(Function) })
      )
    })
    expect(fetchSpy.mock.calls.some(([input]) => String(input).includes("/logs"))).toBe(false)

    const mixin = (
      actionCable.createSubscription.mock.calls[0] as unknown as [unknown, { connected(): void; received(data: { type: string; data?: string }): void }]
    )[1]
    mixin.connected()
    expect(subscription.perform).toHaveBeenCalledWith("receive", { type: "resize", cols: 132, rows: 43 })

    mixin.received({ type: "replay", data: btoa("history\n") })
    mixin.received({ type: "output", data: btoa("live line\n") })

    expect(await screen.findByText(/history/)).toBeInTheDocument()
    expect(screen.getByText(/live line/)).toBeInTheDocument()
    expect(xtermMock.write).toHaveBeenCalledWith(Uint8Array.from(Array.from("live line\n", (character) => character.charCodeAt(0))))
  })

  it("handles terminal relay disconnects gracefully", async () => {
    actionCable.createSubscription.mockReturnValue({ perform: vi.fn(), unsubscribe: vi.fn() })
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({ runtime_sessions: [terminalSessionFixture()] }))

    renderPanel()

    await waitFor(() => expect(actionCable.createSubscription).toHaveBeenCalled())
    const mixin = (actionCable.createSubscription.mock.calls[0] as unknown as [unknown, { received(data: { type: string; data?: string }): void }])[1]
    mixin.received({ type: "disconnected" })

    expect(await screen.findByText("Session ended - reload to reconnect")).toBeInTheDocument()
    expect(screen.getByText("Terminal disconnected")).toBeInTheDocument()
  })

  it("only forwards terminal keyboard input after the operator takes control", async () => {
    const subscription = { perform: vi.fn(), unsubscribe: vi.fn() }
    actionCable.createSubscription.mockReturnValue(subscription)
    vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const url = String(input)
      const method = (init?.method || "GET").toUpperCase()
      if (url.includes("/take_control") && method === "POST") {
        return Promise.resolve(
          jsonResponse({
            runtime_session: terminalSessionFixture(),
            lease: {
              id: 9,
              owner: "user",
              owner_ref: "operator:1",
              mode: "input",
              reason: "Operator took control from the Runtime panel.",
              state: "active",
              acquired_at: "2026-01-01T00:00:00Z",
              expires_at: "2099-01-01T00:00:00Z",
              cancellable: true
            }
          })
        )
      }
      return Promise.resolve(jsonResponse({ runtime_sessions: [terminalSessionFixture()] }))
    })

    renderPanel()

    await waitFor(() => expect(xtermMock.onData).toHaveBeenCalled())
    const onData = xtermMock.onData.mock.calls[0][0] as (data: string) => void
    onData("before\n")
    expect(subscription.perform).not.toHaveBeenCalledWith("receive", { type: "input", data: "before\n" })

    fireEvent.click(screen.getByRole("button", { name: "Take Control" }))
    expect(await screen.findByText("You (input)")).toBeInTheDocument()
    onData("after\n")

    expect(subscription.perform).toHaveBeenCalledWith("receive", { type: "input", data: "after\n" })
  })
})

describe("RuntimePanel control ownership: starting -> running -> agent takes lease -> operator aborts", () => {
  it("walks through the full control lifecycle", async () => {
    // Pin "now" to just before the mocked lease's acquired_at/expires_at
    // below -- otherwise the control-lease heartbeat (which checks the
    // real clock) sees an already-"expired" fixture lease and immediately
    // fires an unmocked renew_control request.
    vi.useFakeTimers({ shouldAdvanceTime: true })
    vi.setSystemTime(new Date("2026-01-01T00:09:59Z"))

    let sessionCalls = 0
    mockFetch((url, method) => {
      if (url.includes("/logs")) return jsonResponse({ entries: [], cursor: 0 })
      if (url.includes("/take_control") && method === "POST") {
        return jsonResponse({
          runtime_session: sessionFixture({ state: "running", active_agent_input_lease: null }),
          lease: {
            id: 9,
            owner: "user",
            owner_ref: "operator:1",
            mode: "input",
            reason: "Operator took control from the Runtime panel.",
            state: "active",
            acquired_at: "2026-01-01T00:10:00Z",
            expires_at: "2026-01-01T00:10:30Z",
            cancellable: true
          }
        })
      }
      if (url.endsWith("/runtime_sessions") && method === "GET") {
        sessionCalls += 1
        if (sessionCalls === 1) {
          return jsonResponse({ runtime_sessions: [sessionFixture({ state: "starting", active_agent_input_lease: null })] })
        }
        return jsonResponse({ runtime_sessions: [sessionFixture({ state: "running", active_agent_input_lease: agentLease() })] })
      }
      return jsonResponse({})
    })

    const client = renderPanel()

    // 1. starting, no one in control yet.
    expect(await screen.findByText("starting")).toBeInTheDocument()
    expect(screen.getByText("None")).toBeInTheDocument()

    // 2. running, and the agent has acquired an input lease (simulates the
    // next poll tick without depending on real timers).
    await act(async () => {
      await client.invalidateQueries()
    })
    expect(await screen.findByText("running")).toBeInTheDocument()
    expect(await screen.findByText("Agent (input)")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Abort Agent Control" })).toBeInTheDocument()

    // 3. the operator aborts agent control and takes over.
    fireEvent.click(screen.getByRole("button", { name: "Abort Agent Control" }))

    expect(await screen.findByText("You (input)")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Release Control" })).toBeInTheDocument()
  })
})

describe("RuntimePanel control lease heartbeat", () => {
  function operatorLeaseFixture(overrides: Partial<RuntimeControlLease> = {}): RuntimeControlLease {
    return {
      id: 9,
      owner: "user",
      owner_ref: "operator:1",
      mode: "input",
      reason: "Operator took control from the Runtime panel.",
      state: "active",
      acquired_at: "2026-01-01T00:00:00.000Z",
      expires_at: "2026-01-01T00:01:00.000Z",
      cancellable: true,
      ...overrides
    }
  }

  it("renews the operator's own lease before it expires instead of letting it lapse", async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true })
    vi.setSystemTime(new Date("2026-01-01T00:00:00.000Z"))

    let renewCalls = 0
    mockFetch((url, method) => {
      if (url.includes("/logs")) return jsonResponse({ entries: [], cursor: 0 })
      if (url.includes("/take_control") && method === "POST") {
        return jsonResponse({ runtime_session: sessionFixture(), lease: operatorLeaseFixture() })
      }
      if (url.includes("/renew_control") && method === "POST") {
        renewCalls += 1
        return jsonResponse({
          runtime_session: sessionFixture(),
          lease: operatorLeaseFixture({ expires_at: "2026-01-01T00:01:50.000Z" })
        })
      }
      if (url.endsWith("/runtime_sessions") && method === "GET") return jsonResponse({ runtime_sessions: [sessionFixture()] })
      return jsonResponse({})
    })

    renderPanel()

    expect(await screen.findByText("running")).toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: "Take Control" }))
    expect(await screen.findByText("You (input)")).toBeInTheDocument()
    expect(renewCalls).toBe(0)

    // The lease was granted for 60s; jump to just inside the renewal margin
    // (the heartbeat checks every 5s and renews once <=15s remain).
    await act(async () => {
      await vi.advanceTimersByTimeAsync(50_000)
    })

    expect(renewCalls).toBeGreaterThan(0)
    expect(screen.getByText("You (input)")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Release Control" })).toBeInTheDocument()
  })

  it("shows a lapsed-control message and reverts to None when the heartbeat can't renew in time", async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true })
    vi.setSystemTime(new Date("2026-01-01T00:00:00.000Z"))

    mockFetch((url, method) => {
      if (url.includes("/logs")) return jsonResponse({ entries: [], cursor: 0 })
      if (url.includes("/take_control") && method === "POST") {
        return jsonResponse({ runtime_session: sessionFixture(), lease: operatorLeaseFixture() })
      }
      if (url.includes("/renew_control") && method === "POST") {
        return jsonResponse({ error: { code: "validation_failed", message: "lease already lapsed" } }, 422)
      }
      if (url.endsWith("/runtime_sessions") && method === "GET") return jsonResponse({ runtime_sessions: [sessionFixture()] })
      return jsonResponse({})
    })

    renderPanel()

    expect(await screen.findByText("running")).toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: "Take Control" }))
    expect(await screen.findByText("You (input)")).toBeInTheDocument()

    await act(async () => {
      await vi.advanceTimersByTimeAsync(50_000)
    })

    expect(await screen.findByText("Control lapsed before it could be renewed. Take Control again to resume.")).toBeInTheDocument()
    expect(screen.getByText("None")).toBeInTheDocument()
  })
})
