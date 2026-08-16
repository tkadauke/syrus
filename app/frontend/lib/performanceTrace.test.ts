import { afterEach, describe, expect, it, vi } from "vitest"
import { recordBrowserTrace, resetBrowserPerformanceObserversForTest, startBrowserPerformanceObservers } from "./performanceTrace"
import { jsonResponse } from "../testSupport"

describe("recordBrowserTrace", () => {
  afterEach(() => {
    vi.restoreAllMocks()
    vi.unstubAllGlobals()
    resetBrowserPerformanceObserversForTest()
    document.getElementById("syrus-bootstrap-data")?.remove()
  })

  it("sends when the caller has live enabled evidence even if initial bootstrap is absent", () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({}))

    recordBrowserTrace({
      trace_id: "trace-1",
      name: "dashboard.route",
      path: "/dashboard/jobs",
      duration_ms: 100,
      visibility_state: "visible"
    }, { enabled: true })

    expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/performance_events", expect.objectContaining({
      method: "POST",
      credentials: "same-origin"
    }))
  })

  it("does not send when the caller has live disabled evidence", () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({}))

    recordBrowserTrace({
      trace_id: "trace-1",
      name: "dashboard.route",
      path: "/dashboard/jobs",
      duration_ms: 100,
      visibility_state: "visible"
    }, { enabled: false })

    expect(fetchSpy).not.toHaveBeenCalled()
  })

  it("records long main-thread tasks through the global browser observer", () => {
    const callbacks: Array<PerformanceObserverCallback> = []
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({}))
    class FakePerformanceObserver {
      static supportedEntryTypes = [ "longtask", "event" ]

      constructor(callback: PerformanceObserverCallback) {
        callbacks.push(callback)
      }

      observe() {}
      disconnect() {}
    }
    vi.stubGlobal("PerformanceObserver", FakePerformanceObserver)

    startBrowserPerformanceObservers({ enabled: true })
    callbacks[0]?.({
      getEntries: () => [ { duration: 125.42, entryType: "longtask", name: "self", startTime: 12.34 } as PerformanceEntry ]
    } as PerformanceObserverEntryList, {} as PerformanceObserver)

    expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/performance_events", expect.objectContaining({
      body: expect.stringContaining("browser.long_task")
    }))
  })

  it("does not start browser observers when performance logging is disabled", () => {
    const observe = vi.fn()
    class FakePerformanceObserver {
      static supportedEntryTypes = [ "longtask" ]

      constructor(_callback: PerformanceObserverCallback) {}

      observe = observe
      disconnect() {}
    }
    vi.stubGlobal("PerformanceObserver", FakePerformanceObserver)

    startBrowserPerformanceObservers({ enabled: false })

    expect(observe).not.toHaveBeenCalled()
  })
})

// A setInterval sampler cannot distinguish a blocked main thread from a timer
// that was never allowed to run. Background tabs clamp timers to about once a
// minute and system sleep stops them entirely, so the next tick's overshoot is
// the throttle or the nap. Production recorded a 3,139,015ms "lag" and hidden
// tabs accounted for 96% of all lag time.
describe("event loop lag sampling", () => {
  const setVisibility = (state: "visible" | "hidden"): void => {
    Object.defineProperty(document, "visibilityState", { value: state, configurable: true })
    document.dispatchEvent(new Event("visibilitychange"))
  }

  afterEach(() => {
    vi.useRealTimers()
    vi.restoreAllMocks()
    vi.unstubAllGlobals()
    resetBrowserPerformanceObserversForTest()
    Object.defineProperty(document, "visibilityState", { value: "visible", configurable: true })
    document.getElementById("syrus-bootstrap-data")?.remove()
  })

  // Fake timers do not advance performance.now(), and a timer that fires on
  // schedule can never look late. Drive the clock by hand so "the tick arrived
  // N ms late" is expressed directly.
  let clock = 0

  const setClock = (value: number): void => {
    clock = value
  }

  const startSampler = (): ReturnType<typeof vi.spyOn> => {
    clock = 0
    // useFakeTimers installs its own performance.now, so take the spy after it
    // or the hand-driven clock is silently replaced.
    vi.useFakeTimers()
    vi.spyOn(performance, "now").mockImplementation(() => clock)
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({}))
    startBrowserPerformanceObservers({
      enabled: true,
      eventLoopIntervalMs: 1_000,
      eventLoopLagThresholdMs: 150,
      minEventLoopReportIntervalMs: 0,
      maxPlausibleEventLoopLagMs: 10_000
    })
    return fetchSpy
  }

  // Fire exactly one sampler tick, having advanced the clock to `at`.
  const tickAt = (at: number): void => {
    setClock(at)
    vi.advanceTimersByTime(1_000)
  }

  const lagBodies = (fetchSpy: ReturnType<typeof vi.spyOn>): Array<Record<string, unknown>> =>
    fetchSpy.mock.calls
      .map(([ , init ]) => JSON.parse(String((init as RequestInit).body)).performance_event)
      .filter((event) => event?.name === "browser.event_loop_lag")

  it("reports a plausible block on a visible tab", () => {
    const fetchSpy = startSampler()

    // Expected at 1000, arrived at 2500: the main thread was busy for 1.5s.
    tickAt(2_500)

    expect(lagBodies(fetchSpy).map((body) => body.duration_ms)).toEqual([ 1_500 ])
  })

  it("does not report while the tab is hidden", () => {
    const fetchSpy = startSampler()
    setVisibility("hidden")

    // Background clamping: one tick, two minutes late.
    tickAt(120_000)

    expect(lagBodies(fetchSpy)).toEqual([])
  })

  it("drops the sample spanning the return to a visible tab", () => {
    const fetchSpy = startSampler()
    setVisibility("hidden")
    tickAt(120_000)
    setVisibility("visible")

    // The first tick back carries the throttled interval, not the page's work.
    tickAt(121_000)

    expect(lagBodies(fetchSpy)).toEqual([])
  })

  it("resumes reporting once the tab has settled after becoming visible", () => {
    const fetchSpy = startSampler()
    setVisibility("hidden")
    tickAt(120_000)
    setVisibility("visible")
    tickAt(121_000)

    tickAt(123_500)

    expect(lagBodies(fetchSpy).map((body) => body.duration_ms)).toEqual([ 1_500 ])
  })

  it("discards implausible lag from a clock discontinuity even when visible", () => {
    const fetchSpy = startSampler()

    // System sleep leaves visibility alone: the tab stays foregrounded, the
    // timer simply does not run for an hour.
    tickAt(3_600_000)

    expect(lagBodies(fetchSpy)).toEqual([])
  })
})
