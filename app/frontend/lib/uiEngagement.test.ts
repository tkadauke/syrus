import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import { engagementRoute, startUiEngagementVisit } from "./uiEngagement"

describe("UI engagement telemetry", () => {
  let monotonic = 0
  let wall = Date.parse("2026-10-24T12:00:00Z")
  const sendBeacon = vi.fn().mockReturnValue(true)

  beforeEach(() => {
    monotonic = 0
    wall = Date.parse("2026-10-24T12:00:00Z")
    vi.stubGlobal("navigator", { ...navigator, sendBeacon })
    Object.defineProperty(document, "visibilityState", { configurable: true, value: "visible" })
    sendBeacon.mockClear()
  })

  afterEach(() => vi.unstubAllGlobals())

  it("allowlists Job, review, and chat routes", () => {
    expect(engagementRoute("/jobs/12", "")).toEqual({ route_id: "job.show", route_params: { job_id: "12" } })
    expect(engagementRoute("/jobs/12", "?tab=review")).toEqual({ route_id: "job.review", route_params: { job_id: "12" } })
    expect(engagementRoute("/chats/9", "")).toEqual({ route_id: "chat.show", route_params: { chat_id: "9" } })
    expect(engagementRoute("/dashboard", "")).toBeNull()
  })

  it("stops active time after 60 seconds without input while visible time continues", async () => {
    const stop = startUiEngagementVisit({ route_id: "job.show", route_params: { job_id: "12" } }, { now: () => monotonic, wallNow: () => wall })
    monotonic = 120_000
    wall += 120_000
    stop()

    const payload = JSON.parse(await (sendBeacon.mock.calls[0][1] as Blob).text()).ui_engagement_sample
    expect(payload.active_ms).toBe(60_000)
    expect(payload.visible_ms).toBe(120_000)
  })

  it("flushes when hidden and begins a new visit when visible again", () => {
    const stop = startUiEngagementVisit({ route_id: "chat.show", route_params: { chat_id: "9" } }, { now: () => monotonic, wallNow: () => wall })
    monotonic = 10_000
    wall += 10_000
    Object.defineProperty(document, "visibilityState", { configurable: true, value: "hidden" })
    document.dispatchEvent(new Event("visibilitychange"))
    expect(sendBeacon).toHaveBeenCalledTimes(1)

    Object.defineProperty(document, "visibilityState", { configurable: true, value: "visible" })
    document.dispatchEvent(new Event("visibilitychange"))
    monotonic = 15_000
    wall += 5_000
    stop()
    expect(sendBeacon).toHaveBeenCalledTimes(2)
  })
})
