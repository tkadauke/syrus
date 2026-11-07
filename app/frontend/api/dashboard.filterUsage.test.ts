import { afterEach, describe, expect, it, vi } from "vitest"
import { jsonResponse } from "../testSupport"
import { recordDashboardFilterUsage } from "./dashboard"

describe("recordDashboardFilterUsage", () => {
  afterEach(() => {
    vi.useRealTimers()
    vi.restoreAllMocks()
  })

  it("debounces rapid changes and records only the latest filter tree", async () => {
    vi.useFakeTimers()
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({ recorded: true }))

    void recordDashboardFilterUsage({ subject: "job", filter: { field: "state", value: "queued" } })
    const latest = recordDashboardFilterUsage({ subject: "job", filter: { field: "state", value: "running" } })

    await vi.advanceTimersByTimeAsync(249)
    expect(fetchSpy).not.toHaveBeenCalled()
    await vi.advanceTimersByTimeAsync(1)
    await latest

    expect(fetchSpy).toHaveBeenCalledTimes(1)
    expect(JSON.parse(String(fetchSpy.mock.calls[0]?.[1]?.body))).toMatchObject({
      subject: "job",
      filter: { field: "state", value: "running" }
    })
  })
})
