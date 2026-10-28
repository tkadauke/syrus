import { afterEach, describe, expect, it, vi } from "vitest"
import { postBrowserTraces, recordBrowserTrace, resetBrowserPerformanceObserversForTest, startBrowserPerformanceObservers } from "./performanceTrace"
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

    recordBrowserTrace(
      {
        trace_id: "trace-1",
        name: "dashboard.route",
        path: "/dashboard/jobs",
        duration_ms: 100,
        visibility_state: "visible"
      },
      { enabled: true }
    )

    expect(fetchSpy).toHaveBeenCalledWith(
      "/api/v1/app/performance_events",
      expect.objectContaining({
        method: "POST",
        credentials: "same-origin"
      })
    )
  })

  it("does not send when the caller has live disabled evidence", () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({}))

    recordBrowserTrace(
      {
        trace_id: "trace-1",
        name: "dashboard.route",
        path: "/dashboard/jobs",
        duration_ms: 100,
        visibility_state: "visible"
      },
      { enabled: false }
    )

    expect(fetchSpy).not.toHaveBeenCalled()
  })

  it("records long main-thread tasks through the global browser observer", () => {
    const callbacks: Array<PerformanceObserverCallback> = []
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({}))
    class FakePerformanceObserver {
      static supportedEntryTypes = ["longtask", "event"]

      constructor(callback: PerformanceObserverCallback) {
        callbacks.push(callback)
      }

      observe() {}
      disconnect() {}
    }
    vi.stubGlobal("PerformanceObserver", FakePerformanceObserver)

    startBrowserPerformanceObservers({ enabled: true })
    callbacks[0]?.(
      {
        getEntries: () => [{ duration: 125.42, entryType: "longtask", name: "self", startTime: 12.34 } as PerformanceEntry]
      } as PerformanceObserverEntryList,
      {} as PerformanceObserver
    )

    expect(fetchSpy).toHaveBeenCalledWith(
      "/api/v1/app/performance_events",
      expect.objectContaining({
        body: expect.stringContaining("browser.long_task")
      })
    )
  })

  it("does not send an empty batch", () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({}))

    postBrowserTraces([], { enabled: true })

    expect(fetchSpy).not.toHaveBeenCalled()
  })

  it("posts a batch of traces in one request", () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({}))

    postBrowserTraces(
      [
        { trace_id: "trace-1", name: "diff_review.parse_diff", path: "/jobs/1?tab=review", duration_ms: 5, visibility_state: "visible" },
        { trace_id: "trace-2", name: "diff_review.syntax_highlight", path: "/jobs/1?tab=review", duration_ms: 40, visibility_state: "visible" }
      ],
      { enabled: true }
    )

    expect(fetchSpy).toHaveBeenCalledTimes(1)
    const body = JSON.parse(String((fetchSpy.mock.calls[0][1] as RequestInit).body))
    expect(body.performance_events).toHaveLength(2)
  })

  it("falls back to fetch when sendBeacon is unavailable even though beacon was requested", () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({}))
    vi.stubGlobal("navigator", { ...navigator, sendBeacon: undefined })

    postBrowserTraces([{ trace_id: "trace-1", name: "diff_review.anchor_scroll", path: "/jobs/1?tab=review", duration_ms: 5, visibility_state: "visible" }], {
      beacon: true,
      enabled: true
    })

    expect(fetchSpy).toHaveBeenCalledTimes(1)
  })

  it("sends a batch via sendBeacon instead of fetch when requested and available", () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({}))
    const sendBeacon = vi.fn().mockReturnValue(true)
    vi.stubGlobal("navigator", { ...navigator, sendBeacon })

    postBrowserTraces([{ trace_id: "trace-1", name: "diff_review.anchor_scroll", path: "/jobs/1?tab=review", duration_ms: 5, visibility_state: "visible" }], {
      beacon: true,
      enabled: true
    })

    expect(sendBeacon).toHaveBeenCalledTimes(1)
    expect(sendBeacon.mock.calls[0][0]).toBe("/api/v1/app/performance_events")
    expect(fetchSpy).not.toHaveBeenCalled()
  })

  it("does not start browser observers when performance logging is disabled", () => {
    const observe = vi.fn()
    class FakePerformanceObserver {
      static supportedEntryTypes = ["longtask"]

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
    window.history.replaceState({}, "", "/")
    document.getElementById("syrus-bootstrap-data")?.remove()
  })

  // Fake timers do not advance performance.now(), and a timer that fires on
  // schedule can never look late. Drive the clock by hand so "the tick arrived
  // N ms late" is expressed directly.
  let clock = 0

  const setClock = (value: number): void => {
    clock = value
  }

  const startSampler = (minReportIntervalMs = 0): ReturnType<typeof vi.spyOn> => {
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
      minEventLoopReportIntervalMs: minReportIntervalMs,
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
      .map((call: unknown[]) => {
        const init = call[1] as RequestInit
        return JSON.parse(String(init.body)).performance_event as Record<string, unknown>
      })
      .filter((event: Record<string, unknown>) => event.name === "browser.event_loop_lag")

  it("reports a plausible block on a visible tab", () => {
    const fetchSpy = startSampler()

    // Expected at 1000, arrived at 2500: the main thread was busy for 1.5s.
    tickAt(2_500)

    const samples = lagBodies(fetchSpy)
    expect(samples.map((body) => body.duration_ms)).toEqual([1_500])
    expect(samples[0].metadata).toMatchObject({
      callback_sequence: 1,
      actual_interval_ms: 2_500,
      expected_interval_ms: 1_000,
      quantized_cadence_run: 0,
      classification: "plausible_main_thread_stall",
      lifecycle_transition_type: "sampler_start"
    })
  })

  it("classifies repeated quantized callback delivery without hiding the samples", () => {
    vi.spyOn(document, "hasFocus").mockReturnValue(false)
    const fetchSpy = startSampler()

    tickAt(2_000)
    tickAt(4_000)
    tickAt(6_000)

    const samples = lagBodies(fetchSpy)
    expect(samples).toHaveLength(3)
    expect(samples.map((body) => (body.metadata as Record<string, unknown>).actual_interval_ms)).toEqual([2_000, 2_000, 2_000])
    expect(samples.map((body) => (body.metadata as Record<string, unknown>).classification)).toEqual([
      "plausible_main_thread_stall",
      "plausible_main_thread_stall",
      "ambiguous_quantized_cadence"
    ])
    expect(samples.map((body) => (body.metadata as Record<string, unknown>).quantized_cadence_run)).toEqual([1, 2, 3])
    expect(samples[2].metadata).toMatchObject({ cadence_multiple: 2, focus_state: "unfocused" })
  })

  it("retains cadence evidence across callbacks omitted by the production report limiter", () => {
    vi.spyOn(document, "hasFocus").mockReturnValue(false)
    const fetchSpy = startSampler(10_000)

    for (let callback = 1; callback <= 10; callback += 1) tickAt(callback * 2_000)

    const samples = lagBodies(fetchSpy)
    expect(samples).toHaveLength(2)
    expect(samples.map((body) => (body.metadata as Record<string, unknown>).callback_sequence)).toEqual([5, 10])
    expect(samples.map((body) => (body.metadata as Record<string, unknown>).quantized_cadence_run)).toEqual([3, 3])
    expect(samples.map((body) => (body.metadata as Record<string, unknown>).classification)).toEqual([
      "ambiguous_quantized_cadence",
      "ambiguous_quantized_cadence"
    ])
  })

  it("keeps route-at-sample-time while correlating one page session", () => {
    const fetchSpy = startSampler()
    window.history.pushState({}, "", "/dashboard/jobs")
    tickAt(2_500)
    window.history.pushState({}, "", "/smart_folders/7")
    tickAt(5_000)

    const samples = lagBodies(fetchSpy)
    expect(samples.map((body) => body.path)).toEqual(["/dashboard/jobs", "/smart_folders/7"])
    const metadata = samples.map((body) => body.metadata as Record<string, unknown>)
    expect(metadata[0].page_session_id).toEqual(metadata[1].page_session_id)
    expect(metadata.map((entry) => entry.callback_sequence)).toEqual([1, 2])
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

    const samples = lagBodies(fetchSpy)
    expect(samples.map((body) => body.duration_ms)).toEqual([1_500])
    expect(samples[0].metadata).toMatchObject({
      actual_interval_ms: 2_500,
      lifecycle_transition_type: "visibility_visible",
      lifecycle_transition_age_ms: 3_500
    })
  })

  it("discards implausible lag from a clock discontinuity even when visible", () => {
    const fetchSpy = startSampler()

    // System sleep leaves visibility alone: the tab stays foregrounded, the
    // timer simply does not run for an hour.
    tickAt(3_600_000)

    expect(lagBodies(fetchSpy)).toEqual([])
  })
})
