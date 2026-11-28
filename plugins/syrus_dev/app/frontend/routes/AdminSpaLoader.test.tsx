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
      entries: [{ id: "chat-route", group: "routes", priority: 1, state, source: null, startedAt: null, durationMs: null }],
      queue: state === "queued" ? ["chat-route"] : [], loading: state === "loading" ? "chat-route" : null,
      paused: true, pauseReasons: ["hidden_tab"], stoppedAfterFailure: false
    },
    startup: {
      milestones: [{ name: "shell_loaded", at_ms: 4 }],
      assets: [{ path: "/assets/spa.js", bytes: 1024, size: 1024, wire_size: 512, source: "service_worker", timing: null }],
      progress_samples: [], progress: null, events: [{ kind: "auto_retry", at_ms: 9000, attempt: 1 }],
      revision: { page: "new", previous: "old", changed: true },
      service_worker: { present: true, controlled: true, registration: { installing: null, waiting: null, active: "activated" }, worker_revision: "new", counted_requests: ["/assets/spa.js"] }, auto_retry_attempt: 1
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
    expect(screen.getByText("shell_loaded")).toBeInTheDocument()
    expect(screen.getByText("/assets/spa.js", { selector: "dt" })).toBeInTheDocument()
    expect(screen.getByText("auto_retry")).toBeInTheDocument()
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
