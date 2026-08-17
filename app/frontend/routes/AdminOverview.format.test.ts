import { describe, expect, it } from "vitest"
import { formatDuration } from "./AdminOverview"

describe("AdminOverview formatDuration", () => {
  it("formats sub-minute durations in seconds", () => {
    expect(formatDuration(45)).toBe("45s")
  })

  it("formats sub-hour durations in minutes", () => {
    expect(formatDuration(150)).toBe("3m")
  })

  it("formats hour-scale durations in hours, not 10x too large", () => {
    // Regression: an earlier version divided by 360 instead of 3600,
    // reporting 2 hours as "20h".
    expect(formatDuration(7200)).toBe("2h")
    expect(formatDuration(5400)).toBe("1.5h")
  })
})
