import { describe, expect, it } from "vitest"
import { startsNewEpicGroup } from "./Dashboard"
import type { DashboardJobItem } from "../api/dashboard"

// Only `id` and `epic` are read by the grouping helper.
function job(id: number, epicId: number | null): DashboardJobItem {
  return { id, epic: epicId === null ? null : { id: epicId, number: epicId, display_number: `#${epicId}`, path: "" } } as unknown as DashboardJobItem
}

describe("startsNewEpicGroup", () => {
  // Queue order: epic56, epic56, epic57, epicless, epicless, epic58
  const items = [ job(1, 56), job(2, 56), job(3, 57), job(4, null), job(5, null), job(6, 58) ]

  it("never separates the first row", () => {
    expect(startsNewEpicGroup(items, 0, true)).toBe(false)
  })

  it("does not separate consecutive jobs of the same Epic", () => {
    expect(startsNewEpicGroup(items, 1, true)).toBe(false)
  })

  it("separates a new Epic from the previous one", () => {
    expect(startsNewEpicGroup(items, 2, true)).toBe(true)
  })

  it("separates an epicless job from a preceding Epic", () => {
    expect(startsNewEpicGroup(items, 3, true)).toBe(true)
  })

  it("does not separate consecutive epicless jobs (no epic boundary)", () => {
    expect(startsNewEpicGroup(items, 4, true)).toBe(false)
  })

  it("separates an Epic that follows epicless jobs", () => {
    expect(startsNewEpicGroup(items, 5, true)).toBe(true)
  })

  it("never separates when grouping is disabled (non-queue sort)", () => {
    expect(items.map((_, index) => startsNewEpicGroup(items, index, false))).toEqual(items.map(() => false))
  })
})
