import { act, fireEvent, render, screen } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { beforeEach, describe, expect, it, vi } from "vitest"

const diagnostics = vi.hoisted(() => ({
  listener: null as (() => void) | null,
  current: null as unknown,
  warmEverythingNow: vi.fn(),
  clearWarmupState: vi.fn()
}))

vi.mock("@app/pluginSdk", () => ({
  spaLoaderDiagnostics: {
    snapshot: () => diagnostics.current,
    subscribe: (listener: () => void) => {
      diagnostics.listener = listener
      return () => { diagnostics.listener = null }
    },
    warmEverythingNow: diagnostics.warmEverythingNow,
    clearWarmupState: diagnostics.clearWarmupState
  }
}))

import { AdminSpaLoader } from "./AdminSpaLoader"

function snapshot(state = "queued") {
  return {
    warmup: {
      entries: [{ id: "chat-route", group: "routes", priority: 1, state, source: null, startedAt: null, durationMs: null, manifestKey: "app/frontend/routes/Chat.tsx", size: 8192 }],
      queue: state === "queued" ? ["chat-route"] : [], loading: state === "loading" ? "chat-route" : null,
      paused: true, pauseReasons: ["hidden_tab"], stoppedAfterFailure: false
    },
    startup: {
      milestones: [{ name: "shell_loaded", at_ms: 4 }],
      assets: [{ path: "/assets/spa.js", bytes: 1024, size: 1024, wire_size: 512, budget_size: 600, source: "service_worker", timing: { request_start_ms: 10, response_start_ms: 25, response_end_ms: 40 } }],
      progress_samples: [], progress: null, events: [{ kind: "auto_retry", at_ms: 9000, attempt: 1 }, { kind: "stale_chunk_failure", at_ms: 9100, outcome: "reload", revision: "new" }],
      lazy_chunks: { "app/frontend/routes/Chat.tsx": { file: "spa-Chat.js", size: 8192 } },
      revision: { page: "new", previous: "old", changed: true },
      current_state: "ready",
      last_problem_state: "watchdog",
      service_worker: { present: true, controlled: true, registration: { installing: null, waiting: null, active: "activated" }, worker_revision: "new", counted_requests: ["/assets/spa.js"] },
      auto_retry_attempt: 1, maximum_auto_retry_attempt: 2
    }
  }
}

describe("AdminSpaLoader", () => {
  beforeEach(() => {
    diagnostics.current = snapshot()
    diagnostics.listener = null
    diagnostics.warmEverythingNow.mockClear()
    diagnostics.clearWarmupState.mockClear()
  })

  it("renders every diagnostic section from the host SDK snapshot and updates live", () => {
    render(<MemoryRouter initialEntries={["/admin/spa_loader"]}><AdminSpaLoader /></MemoryRouter>)

    expect(screen.getByText("chat-route", { selector: "td" })).toBeInTheDocument()
    expect(screen.getByText(/chat-route \(routes, priority 1\)/)).toBeInTheDocument()
    expect(screen.getByText("shell_loaded")).toBeInTheDocument()
    expect(screen.getByText("/assets/spa.js", { selector: "dt" })).toBeInTheDocument()
    expect(screen.getByText("Automatic retry")).toBeInTheDocument()
    expect(screen.getByText("Stale chunk failure")).toBeInTheDocument()
    expect(screen.getByText(/Reloaded page.*new.*9100 ms/)).toBeInTheDocument()
    expect(screen.getByText("8 KB")).toBeInTheDocument()
    expect(screen.getByText(/Service worker.*request 10 ms.*first byte 25 ms.*complete 40 ms/)).toBeInTheDocument()
    expect(screen.getByText("old → new")).toBeInTheDocument()
    expect(screen.getByText("Ready")).toBeInTheDocument()
    expect(screen.getByText("Still loading")).toBeInTheDocument()
    expect(screen.getByText("2", { selector: "dd" })).toBeInTheDocument()
    expect(screen.getAllByText("Yes")).toHaveLength(2)
    expect(screen.getByText("Activated")).toBeInTheDocument()
    expect(screen.getByText("new / new")).toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: "Warm everything now" }))
    fireEvent.click(screen.getByRole("button", { name: "Clear warm-up state" }))
    expect(diagnostics.warmEverythingNow).toHaveBeenCalledOnce()
    expect(diagnostics.clearWarmupState).toHaveBeenCalledOnce()

    diagnostics.current = snapshot("loaded")
    act(() => diagnostics.listener?.())
    expect(screen.getByText("Loaded")).toBeInTheDocument()
  })
})
