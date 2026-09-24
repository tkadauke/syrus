import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import { currentVisibilityState, flushClientMetricsQueue, recordClientMetric, resetClientMetricsForTest, resourceTagFor } from "./clientMetrics"
import { jsonResponse } from "../testSupport"

function sentBatches(fetchSpy: ReturnType<typeof vi.spyOn>): Array<Record<string, unknown>[]> {
  return fetchSpy.mock.calls.map((call: unknown[]) => {
    const init = call[1] as RequestInit
    return JSON.parse(String(init.body)).client_metrics as Record<string, unknown>[]
  })
}

describe("clientMetrics", () => {
  let fetchSpy: ReturnType<typeof vi.spyOn>

  beforeEach(() => {
    fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({}))
  })

  afterEach(() => {
    resetClientMetricsForTest()
    vi.restoreAllMocks()
  })

  it("batches repeated increments for the same name/resource into one entry with a summed count", () => {
    recordClientMetric("entity_patch_applications", "job")
    recordClientMetric("entity_patch_applications", "job")
    recordClientMetric("entity_patch_applications", "chat")

    flushClientMetricsQueue()

    const [ batch ] = sentBatches(fetchSpy)
    expect(batch).toEqual(expect.arrayContaining([
      { name: "entity_patch_applications", resource: "job", by: 2 },
      { name: "entity_patch_applications", resource: "chat", by: 1 }
    ]))
    expect(batch).toHaveLength(2)
  })

  it("does not send a request when nothing was recorded", () => {
    flushClientMetricsQueue()

    expect(fetchSpy).not.toHaveBeenCalled()
  })

  it("keeps entries with the same name/resource but different visibility states separate", () => {
    recordClientMetric("entity_patch_applications", "job", "visible")
    recordClientMetric("entity_patch_applications", "job", "hidden")
    recordClientMetric("entity_patch_applications", "job", "hidden")

    flushClientMetricsQueue()

    const [ batch ] = sentBatches(fetchSpy)
    expect(batch).toEqual(expect.arrayContaining([
      { name: "entity_patch_applications", resource: "job", visibility_state: "visible", by: 1 },
      { name: "entity_patch_applications", resource: "job", visibility_state: "hidden", by: 2 }
    ]))
  })

  describe("currentVisibilityState", () => {
    it("reads document.visibilityState when it is visible or hidden", () => {
      vi.spyOn(document, "visibilityState", "get").mockReturnValue("hidden")
      expect(currentVisibilityState()).toEqual("hidden")

      vi.spyOn(document, "visibilityState", "get").mockReturnValue("visible")
      expect(currentVisibilityState()).toEqual("visible")
    })
  })

  describe("resourceTagFor", () => {
    it("normalizes a plural query-key root to the backend's singular vocabulary", () => {
      expect(resourceTagFor("jobs")).toEqual("job")
      expect(resourceTagFor("chats")).toEqual("chat")
    })

    it("accepts an already-singular application-event resource", () => {
      expect(resourceTagFor("job")).toEqual("job")
    })

    it("falls back to unknown for anything outside the closed vocabulary", () => {
      expect(resourceTagFor("smart_folders")).toEqual("unknown")
      expect(resourceTagFor(null)).toEqual("unknown")
      expect(resourceTagFor(undefined)).toEqual("unknown")
    })
  })
})
