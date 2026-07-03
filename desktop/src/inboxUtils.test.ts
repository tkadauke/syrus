import { describe, it, expect } from "vitest"
import { groupJobsByEpic, epicFullyImplemented } from "./inboxUtils"
import type { JobItemForGrouping } from "./inboxUtils"

const makeJob = (overrides: Partial<JobItemForGrouping> & { id: number }): JobItemForGrouping => ({
  epic_id: null,
  epic_title: null,
  branch_name: null,
  ...overrides
})

describe("groupJobsByEpic", () => {
  it("returns job entries for epicless jobs", () => {
    const jobs = [makeJob({ id: 1 }), makeJob({ id: 2 })]
    const result = groupJobsByEpic(jobs)
    expect(result).toEqual([
      { kind: "job", job: jobs[0] },
      { kind: "job", job: jobs[1] }
    ])
  })

  it("groups jobs with the same epic_id into one epic entry", () => {
    const jobs = [
      makeJob({ id: 10, epic_id: 5, epic_title: "My Epic" }),
      makeJob({ id: 11, epic_id: 5, epic_title: "My Epic" })
    ]
    const result = groupJobsByEpic(jobs)
    expect(result).toHaveLength(1)
    expect(result[0]).toEqual({ kind: "epic", epicId: 5, epicTitle: "My Epic", jobs })
  })

  it("preserves relative order between epic groups and epicless jobs", () => {
    const jobs = [
      makeJob({ id: 1 }),
      makeJob({ id: 2, epic_id: 10, epic_title: "Epic A" }),
      makeJob({ id: 3, epic_id: 10, epic_title: "Epic A" }),
      makeJob({ id: 4 }),
      makeJob({ id: 5, epic_id: 20, epic_title: "Epic B" })
    ]
    const result = groupJobsByEpic(jobs)
    expect(result).toHaveLength(4)
    expect(result[0]).toEqual({ kind: "job", job: jobs[0] })
    expect(result[1]).toMatchObject({ kind: "epic", epicId: 10, jobs: [jobs[1], jobs[2]] })
    expect(result[2]).toEqual({ kind: "job", job: jobs[3] })
    expect(result[3]).toMatchObject({ kind: "epic", epicId: 20, jobs: [jobs[4]] })
  })

  it("uses 'Epic' as fallback title when epic_title is null", () => {
    const jobs = [makeJob({ id: 1, epic_id: 7, epic_title: null })]
    const result = groupJobsByEpic(jobs)
    expect(result[0]).toMatchObject({ kind: "epic", epicTitle: "Epic" })
  })

  it("uses 'Epic' as fallback title when epic_title is undefined", () => {
    const jobs = [{ id: 1, epic_id: 7 } as JobItemForGrouping]
    const result = groupJobsByEpic(jobs)
    expect(result[0]).toMatchObject({ kind: "epic", epicTitle: "Epic" })
  })

  it("returns an empty array for an empty input", () => {
    expect(groupJobsByEpic([])).toEqual([])
  })
})

describe("epicFullyImplemented", () => {
  it("returns false for an empty list", () => {
    expect(epicFullyImplemented([])).toBe(false)
  })

  it("returns true when all jobs have a non-empty branch_name", () => {
    const jobs = [
      makeJob({ id: 1, branch_name: "feature/branch-1" }),
      makeJob({ id: 2, branch_name: "feature/branch-2" })
    ]
    expect(epicFullyImplemented(jobs)).toBe(true)
  })

  it("returns false when any job has a null branch_name", () => {
    const jobs = [
      makeJob({ id: 1, branch_name: "feature/branch-1" }),
      makeJob({ id: 2, branch_name: null })
    ]
    expect(epicFullyImplemented(jobs)).toBe(false)
  })

  it("returns false when any job has an empty string branch_name", () => {
    const jobs = [
      makeJob({ id: 1, branch_name: "feature/branch-1" }),
      makeJob({ id: 2, branch_name: "   " })
    ]
    expect(epicFullyImplemented(jobs)).toBe(false)
  })

  it("returns false when any job has an undefined branch_name", () => {
    const jobs = [
      makeJob({ id: 1, branch_name: "feature/branch-1" }),
      makeJob({ id: 2 })
    ]
    expect(epicFullyImplemented(jobs)).toBe(false)
  })
})
