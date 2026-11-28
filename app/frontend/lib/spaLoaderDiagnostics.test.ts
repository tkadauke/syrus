import { beforeEach, describe, expect, it, vi } from "vitest"

const upstream = vi.hoisted(() => ({
  warmupListener: null as (() => void) | null,
  stopWarmup: vi.fn(),
  warmEverythingNow: vi.fn(),
  clearWarmupState: vi.fn(),
  snapshot: vi.fn(() => ({
    entries: [
      {
        id: "route:Chat",
        group: null,
        priority: 0,
        state: "queued",
        source: null,
        startedAt: null,
        durationMs: null,
        manifestKey: "app/frontend/routes/Chat.tsx",
        size: null
      }
    ],
    queue: ["route:Chat"],
    loading: null,
    paused: false,
    pauseReasons: [],
    stoppedAfterFailure: false
  }))
}))

vi.mock("./chunkWarmup", () => ({
  chunkWarmup: {
    snapshot: upstream.snapshot,
    subscribe: (listener: () => void) => {
      upstream.warmupListener = listener
      return upstream.stopWarmup
    },
    warmEverythingNow: upstream.warmEverythingNow,
    clearWarmupState: upstream.clearWarmupState
  }
}))

function startupSnapshot() {
  return {
    milestones: [],
    assets: [],
    progress_samples: [],
    progress: null,
    budget: null,
    lazy_chunks: { "app/frontend/routes/Chat.tsx": { file: "spa-Chat.js", size: 8192 } },
    events: [],
    revision: { page: "current", previous: null, changed: false },
    current_state: "ready",
    last_problem_state: null,
    service_worker: { present: false, controlled: false, registration: null, worker_revision: null, counted_requests: [] },
    auto_retry_attempt: 0,
    maximum_auto_retry_attempt: 0
  }
}

describe("spaLoaderDiagnostics", () => {
  beforeEach(() => {
    vi.resetModules()
    upstream.warmupListener = null
    upstream.stopWarmup.mockClear()
    upstream.warmEverythingNow.mockClear()
    upstream.clearWarmupState.mockClear()
    upstream.snapshot.mockClear()
    delete window.SyrusStartupDiagnostics
  })

  it("activates upstreams for the first subscriber, fans out updates, and tears down after the last", async () => {
    const startupListener = vi.fn()
    const stopStartup = vi.fn()
    window.SyrusStartupDiagnostics = {
      mark: vi.fn(),
      snapshot: startupSnapshot,
      subscribe: (listener) => {
        startupListener.mockImplementation(listener)
        return stopStartup
      }
    }
    const { spaLoaderDiagnostics } = await import("./spaLoaderDiagnostics")
    const first = vi.fn()
    const second = vi.fn()
    const unsubscribeFirst = spaLoaderDiagnostics.subscribe(first)
    const unsubscribeSecond = spaLoaderDiagnostics.subscribe(second)

    const snapshot = spaLoaderDiagnostics.snapshot()
    expect(spaLoaderDiagnostics.snapshot()).toBe(snapshot)
    expect(snapshot.warmup.entries[0].size).toBe(8192)
    upstream.warmupListener?.()
    expect(first).toHaveBeenCalledOnce()
    expect(second).toHaveBeenCalledOnce()
    startupListener()
    expect(first).toHaveBeenCalledTimes(2)

    unsubscribeFirst()
    expect(upstream.stopWarmup).not.toHaveBeenCalled()
    unsubscribeSecond()
    expect(upstream.stopWarmup).toHaveBeenCalledOnce()
    expect(stopStartup).toHaveBeenCalledOnce()
  })

  it("delegates the in-tab testing actions", async () => {
    const { spaLoaderDiagnostics } = await import("./spaLoaderDiagnostics")

    spaLoaderDiagnostics.warmEverythingNow()
    spaLoaderDiagnostics.clearWarmupState()

    expect(upstream.warmEverythingNow).toHaveBeenCalledOnce()
    expect(upstream.clearWarmupState).toHaveBeenCalledOnce()
  })
})
