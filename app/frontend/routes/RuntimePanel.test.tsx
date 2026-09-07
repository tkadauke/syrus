import { jsonResponse } from "../testSupport"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { act, fireEvent, render, screen } from "@testing-library/react"
import { describe, expect, it, vi } from "vitest"
import { RuntimePanel } from "./RuntimePanel"
import type { RuntimeControlLease, RuntimeSession } from "../api/chats"

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
      return jsonResponse({ runtime_sessions: [ sessionFixture() ] })
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
        runtime_sessions: [ sessionFixture({ latest_frame_url: "/api/v1/app/chats/8/runtime_sessions/101/frame", latest_frame_at: "2026-01-01T00:00:00Z" }) ]
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
        if (cursor === "0" || cursor === null) return jsonResponse({ entries: [ "line-1" ], cursor: 1 })
        return jsonResponse({ entries: [], cursor: 1 })
      }
      return jsonResponse({ runtime_sessions: [ sessionFixture() ] })
    })

    renderPanel()

    expect(await screen.findByText("line-1")).toBeInTheDocument()
    expect(logCalls).toBeGreaterThan(0)
  })
})

describe("RuntimePanel capture action", () => {
  it("captures a screenshot and refreshes the session in place", async () => {
    mockFetch((url, method) => {
      if (url.includes("/logs")) return jsonResponse({ entries: [], cursor: 0 })
      if (url.includes("/capture") && method === "POST") {
        return jsonResponse({
          runtime_session: sessionFixture({ latest_frame_url: "/api/v1/app/chats/8/runtime_sessions/101/frame", latest_frame_at: "2026-01-01T00:05:00Z" })
        })
      }
      return jsonResponse({ runtime_sessions: [ sessionFixture() ] })
    })

    renderPanel()

    await screen.findByText("No screenshot captured yet.")
    fireEvent.click(screen.getByRole("button", { name: "Capture" }))

    expect(await screen.findByAltText("Latest screenshot")).toBeInTheDocument()
  })
})

describe("RuntimePanel control ownership: starting -> running -> agent takes lease -> operator aborts", () => {
  it("walks through the full control lifecycle", async () => {
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
          return jsonResponse({ runtime_sessions: [ sessionFixture({ state: "starting", active_agent_input_lease: null }) ] })
        }
        return jsonResponse({ runtime_sessions: [ sessionFixture({ state: "running", active_agent_input_lease: agentLease() }) ] })
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
