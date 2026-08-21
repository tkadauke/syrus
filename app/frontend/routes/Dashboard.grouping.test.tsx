import { describe, expect, it } from "vitest"
import { startsNewEpicGroup } from "./dashboard/JobsTable"
import type { DashboardJobItem } from "../api/dashboard"

// Only `id`, `epic`, and `landing_queue_entry_key` are read by the grouping helper.
function job(id: number, epicId: number | null, landingQueueEntryKey: string | null = null): DashboardJobItem {
  return {
    id,
    epic: epicId === null ? null : { id: epicId, number: epicId, display_number: `#${epicId}`, path: "" },
    landing_queue_entry_key: landingQueueEntryKey
  } as unknown as DashboardJobItem
}

function bundledJob(id: number, bundleId: number): DashboardJobItem {
  return job(id, null, `job_bundle:${bundleId}`)
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

describe("startsNewEpicGroup with job bundles", () => {
  // Queue order: bundle9, bundle9, standalone, standalone, epic56, bundle10
  const items = [
    bundledJob(1, 9), bundledJob(2, 9),
    job(3, null, "job:3"), job(4, null, "job:4"),
    job(5, 56), bundledJob(6, 10)
  ]

  it("does not separate consecutive jobs of the same bundle", () => {
    expect(startsNewEpicGroup(items, 1, true)).toBe(false)
  })

  it("separates a standalone job from a preceding bundle", () => {
    expect(startsNewEpicGroup(items, 2, true)).toBe(true)
  })

  it("does not separate consecutive unbundled standalone jobs", () => {
    expect(startsNewEpicGroup(items, 3, true)).toBe(false)
  })

  it("separates an Epic that follows a standalone job", () => {
    expect(startsNewEpicGroup(items, 4, true)).toBe(true)
  })

  it("separates a different bundle from a preceding Epic", () => {
    expect(startsNewEpicGroup(items, 5, true)).toBe(true)
  })

  it("never separates when grouping is disabled (non-queue sort)", () => {
    expect(items.map((_, index) => startsNewEpicGroup(items, index, false))).toEqual(items.map(() => false))
  })
})
