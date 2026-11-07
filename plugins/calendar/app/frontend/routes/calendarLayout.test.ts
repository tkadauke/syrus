import { describe, expect, it } from "vitest"
import type { CalendarEvent } from "../api/calendar"
import { DAY_HEIGHT, HOUR_HEIGHT, positionEvents, resolveDuration, zonedParts } from "./calendarLayout"

const event = (id: string, starts_at: string, extra: Partial<CalendarEvent> = {}): CalendarEvent => ({
  source_id: "calendar:test",
  id,
  kind: "test",
  title: id,
  starts_at,
  destination_path: "/test",
  state: "planned",
  metadata: {},
  ...extra
})

describe("calendar time-grid layout", () => {
  it("uses a constant 24-hour scale and minute-accurate positions", () => {
    const [item] = positionEvents([event("quarter", "2026-11-02T10:15:00Z")], "UTC")
    expect(HOUR_HEIGHT).toBe(48)
    expect(DAY_HEIGHT).toBe(24 * HOUR_HEIGHT)
    expect(item.top).toBe(10.25 * HOUR_HEIGHT)
    expect(item.height).toBe(0.5 * HOUR_HEIGHT)
  })

  it("resolves actual, planned, provider, and fallback duration provenance", () => {
    expect(
      resolveDuration(
        event("actual", "2026-11-02T10:00:00Z", {
          actual_started_at: "2026-11-02T10:01:00Z",
          actual_finished_at: "2026-11-02T10:11:00Z"
        })
      ).provenance
    ).toBe("actual")
    expect(resolveDuration(event("planned", "2026-11-02T10:00:00Z", { ends_at: "2026-11-02T11:00:00Z" })).provenance).toBe("planned")
    expect(
      resolveDuration(
        event("learned", "2026-11-02T10:00:00Z", {
          estimated_duration_seconds: 900,
          duration_estimate_provenance: "representative"
        })
      )
    ).toEqual({ seconds: 900, provenance: "representative", estimated: true })
    expect(resolveDuration(event("fallback", "2026-11-02T10:00:00Z"))).toEqual({ seconds: 1800, provenance: "fallback", estimated: true })
  })

  it("allocates overlapping events to side-by-side lanes", () => {
    const positioned = positionEvents(
      [
        event("first", "2026-11-02T10:00:00Z", { ends_at: "2026-11-02T11:00:00Z" }),
        event("second", "2026-11-02T10:30:00Z", { ends_at: "2026-11-02T11:30:00Z" }),
        event("later", "2026-11-02T12:00:00Z")
      ],
      "UTC"
    )
    expect(positioned.slice(0, 2).map(({ lane, laneCount }) => [lane, laneCount])).toEqual([
      [0, 2],
      [1, 2]
    ])
    expect(positioned[2]).toMatchObject({ lane: 0, laneCount: 1 })
  })

  it("assigns timezone-local days and minutes across UTC boundaries", () => {
    expect(zonedParts(new Date("2026-11-02T00:30:00Z"), "America/Los_Angeles")).toEqual({ dayKey: "2026-11-01", minute: 16 * 60 + 30 })
    expect(zonedParts(new Date("2026-11-02T23:30:00Z"), "Asia/Tokyo")).toEqual({ dayKey: "2026-11-03", minute: 8 * 60 + 30 })
  })
})
