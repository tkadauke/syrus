import { renderHook } from "@testing-library/react"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import {
  endMarker,
  flushPerformanceMarkerQueue,
  measureAsync,
  measureSync,
  recordCount,
  resetPerformanceMarkersForTest,
  startMarker,
  useMarkedRender
} from "./performanceMarkers"
import { jsonResponse } from "../testSupport"

function sentBatches(fetchSpy: ReturnType<typeof vi.spyOn>): Array<Record<string, unknown>[]> {
  return fetchSpy.mock.calls.map((call: unknown[]) => {
    const init = call[1] as RequestInit
    return JSON.parse(String(init.body)).performance_events as Record<string, unknown>[]
  })
}

describe("performanceMarkers", () => {
  let fetchSpy: ReturnType<typeof vi.spyOn>

  beforeEach(() => {
    fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({}))
  })

  afterEach(() => {
    resetPerformanceMarkersForTest()
    vi.restoreAllMocks()
    vi.unstubAllGlobals()
    document.getElementById("syrus-bootstrap-data")?.remove()
  })

  describe("measureSync", () => {
    it("returns the wrapped function's result and records its duration", () => {
      let clock = 100
      vi.spyOn(performance, "now").mockImplementation(() => clock)

      const result = measureSync(
        "diff_review.parse_diff",
        () => {
          clock += 12.34
          return 42
        },
        { enabled: true }
      )

      expect(result).toBe(42)
      flushPerformanceMarkerQueue()
      const [batch] = sentBatches(fetchSpy)
      expect(batch).toEqual([expect.objectContaining({ name: "diff_review.parse_diff", duration_ms: 12.3 })])
    })

    it("propagates a thrown error and still records the span", () => {
      let clock = 0
      vi.spyOn(performance, "now").mockImplementation(() => clock)

      expect(() =>
        measureSync(
          "diff_review.parse_diff",
          () => {
            clock += 5
            throw new Error("parse failed")
          },
          { enabled: true }
        )
      ).toThrow("parse failed")

      flushPerformanceMarkerQueue()
      expect(sentBatches(fetchSpy)[0]).toHaveLength(1)
    })

    it("still runs the wrapped function when performance logging is disabled, but records nothing", () => {
      const fn = vi.fn(() => "value")

      const result = measureSync("diff_review.parse_diff", fn, { enabled: false })

      expect(result).toBe("value")
      expect(fn).toHaveBeenCalledTimes(1)
      flushPerformanceMarkerQueue()
      expect(fetchSpy).not.toHaveBeenCalled()
    })
  })

  describe("measureAsync", () => {
    it("awaits and resolves with the wrapped promise's value", async () => {
      const result = await measureAsync("diff_review.fetch_source_diff", async () => "diff-payload", { enabled: true })

      expect(result).toBe("diff-payload")
      flushPerformanceMarkerQueue()
      expect(sentBatches(fetchSpy)[0]).toEqual([expect.objectContaining({ name: "diff_review.fetch_source_diff" })])
    })

    it("propagates a rejection and still records the span", async () => {
      await expect(
        measureAsync(
          "diff_review.fetch_source_diff",
          async () => {
            throw new Error("network down")
          },
          { enabled: true }
        )
      ).rejects.toThrow("network down")

      flushPerformanceMarkerQueue()
      expect(sentBatches(fetchSpy)[0]).toHaveLength(1)
    })
  })

  describe("thresholding", () => {
    it("drops a span shorter than thresholdMs", () => {
      let clock = 0
      vi.spyOn(performance, "now").mockImplementation(() => clock)

      measureSync(
        "diff_review.viewport_render",
        () => {
          clock += 5
        },
        { enabled: true, thresholdMs: 16 }
      )

      flushPerformanceMarkerQueue()
      expect(fetchSpy).not.toHaveBeenCalled()
    })

    it("keeps a span at or above thresholdMs", () => {
      let clock = 0
      vi.spyOn(performance, "now").mockImplementation(() => clock)

      measureSync(
        "diff_review.viewport_render",
        () => {
          clock += 20
        },
        { enabled: true, thresholdMs: 16 }
      )

      flushPerformanceMarkerQueue()
      expect(sentBatches(fetchSpy)[0]).toHaveLength(1)
    })
  })

  describe("sampling", () => {
    it("drops every sample when sampleRate is 0", () => {
      vi.spyOn(Math, "random").mockReturnValue(0.999)

      for (let i = 0; i < 5; i += 1) recordCount("diff_review.files_menu_open", { enabled: true, sampleRate: 0 })

      flushPerformanceMarkerQueue()
      expect(fetchSpy).not.toHaveBeenCalled()
    })

    it("keeps samples that land under the sample rate's random draw", () => {
      vi.spyOn(Math, "random").mockReturnValue(0.1)

      recordCount("diff_review.files_menu_open", { enabled: true, sampleRate: 0.5 })

      flushPerformanceMarkerQueue()
      expect(sentBatches(fetchSpy)[0]).toHaveLength(1)
    })
  })

  describe("per-session cap", () => {
    it("stops recording a marker name once maxPerSession is reached", () => {
      for (let i = 0; i < 5; i += 1) recordCount("diff_review.files_menu_open", { enabled: true, maxPerSession: 2 })

      flushPerformanceMarkerQueue()
      expect(sentBatches(fetchSpy)[0]).toHaveLength(2)
    })

    it("tracks the cap independently per marker name", () => {
      recordCount("diff_review.files_menu_open", { enabled: true, maxPerSession: 1 })
      recordCount("diff_review.anchor_scroll", { enabled: true, maxPerSession: 1 })

      flushPerformanceMarkerQueue()
      const names = sentBatches(fetchSpy)[0].map((event) => event.name)
      expect(names).toEqual(expect.arrayContaining(["diff_review.files_menu_open", "diff_review.anchor_scroll"]))
    })
  })

  describe("recordCount", () => {
    it("records a zero-duration event carrying the count in metadata", () => {
      recordCount("diff_review.comment_threads_render", { enabled: true, count: 7, metadata: { selected_path: "app/main.rb" } })

      flushPerformanceMarkerQueue()
      expect(sentBatches(fetchSpy)[0]).toEqual([
        expect.objectContaining({
          name: "diff_review.comment_threads_render",
          duration_ms: 0,
          metadata: { count: 7, selected_path: "app/main.rb" }
        })
      ])
    })
  })

  describe("startMarker/endMarker", () => {
    it("records the elapsed time between start and end, with correlation ids and extra metadata merged in", () => {
      let clock = 0
      vi.spyOn(performance, "now").mockImplementation(() => clock)

      const handle = startMarker("diff_review.files_menu_open", { enabled: true, interactionId: "interaction-1", metadata: { total_files: 42 } })
      clock += 8.2
      endMarker(handle, { metadata: { popup_rendered: true } })

      flushPerformanceMarkerQueue()
      expect(sentBatches(fetchSpy)[0]).toEqual([
        expect.objectContaining({
          name: "diff_review.files_menu_open",
          duration_ms: 8.2,
          interaction_id: "interaction-1",
          metadata: { total_files: 42, popup_rendered: true }
        })
      ])
    })
  })

  describe("batching", () => {
    it("sends multiple queued markers as a single request", () => {
      recordCount("diff_review.files_menu_open", { enabled: true })
      recordCount("diff_review.anchor_scroll", { enabled: true })
      recordCount("diff_review.comment_threads_render", { enabled: true })

      flushPerformanceMarkerQueue()

      expect(fetchSpy).toHaveBeenCalledTimes(1)
      expect(sentBatches(fetchSpy)[0]).toHaveLength(3)
    })

    it("auto-flushes once the queue reaches its size cap without a manual flush", () => {
      for (let i = 0; i < 20; i += 1) recordCount(`diff_review.marker_${i}`, { enabled: true, maxPerSession: Infinity })

      expect(fetchSpy).toHaveBeenCalledTimes(1)
      expect(sentBatches(fetchSpy)[0]).toHaveLength(20)
    })

    it("flushes the queue via sendBeacon when the tab becomes hidden", () => {
      const sendBeacon = vi.fn().mockReturnValue(true)
      vi.stubGlobal("navigator", { ...navigator, sendBeacon })

      recordCount("diff_review.anchor_scroll", { enabled: true })
      Object.defineProperty(document, "visibilityState", { value: "hidden", configurable: true })
      document.dispatchEvent(new Event("visibilitychange"))

      expect(sendBeacon).toHaveBeenCalledTimes(1)
      expect(fetchSpy).not.toHaveBeenCalled()
      Object.defineProperty(document, "visibilityState", { value: "visible", configurable: true })
    })
  })

  describe("useMarkedRender", () => {
    it("records a commit-phase render duration once per mount", () => {
      let clock = 0
      vi.spyOn(performance, "now").mockImplementation(() => clock)

      const { unmount } = renderHook(() => {
        clock += 3
        useMarkedRender("diff_review.initial_render", { enabled: true, metadata: { total_files: 5 } })
      })

      flushPerformanceMarkerQueue()
      expect(sentBatches(fetchSpy)[0]).toEqual([expect.objectContaining({ name: "diff_review.initial_render", metadata: { total_files: 5 } })])
      unmount()
    })

    it("does not re-record on every re-render when deps are omitted", () => {
      let clock = 0
      vi.spyOn(performance, "now").mockImplementation(() => clock)

      const { rerender } = renderHook(() => {
        clock += 1
        useMarkedRender("diff_review.initial_render", { enabled: true })
      })
      rerender()
      rerender()

      flushPerformanceMarkerQueue()
      expect(sentBatches(fetchSpy)[0]).toHaveLength(1)
    })
  })
})
