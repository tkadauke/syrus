import { describe, expect, it } from "vitest"
import { keepPreviousDataWithin } from "./placeholderData"

const prev = (key: unknown[]) => ({ queryKey: key }) as never

describe("keepPreviousDataWithin", () => {
  it("keeps previous data when identity segments match", () => {
    const fn = keepPreviousDataWithin(["jobs", "1", "source", "?ref=b"], [0, 1])
    expect(fn("old", prev(["jobs", "1", "source", "?ref=a"]))).toBe("old")
  })

  it("drops previous data when identity differs", () => {
    const fn = keepPreviousDataWithin(["jobs", "2", "source", "?ref=a"], [0, 1])
    expect(fn("old", prev(["jobs", "1", "source", "?ref=a"]))).toBeUndefined()
  })

  it("compares object segments structurally and ignores non-identity segments", () => {
    const fn = keepPreviousDataWithin(["admin", "transcript", "5", { page: 2 }], [0, 1, 2])
    expect(fn("old", prev(["admin", "transcript", "5", { page: 1 }]))).toBe("old")
    expect(fn("old", prev(["admin", "transcript", "6", { page: 1 }]))).toBeUndefined()
  })

  it("returns undefined without a previous query or when the key is too short", () => {
    const fn = keepPreviousDataWithin(["chats", "1"], [0, 1])
    expect(fn("old", undefined)).toBeUndefined()
    expect(fn("old", prev(["chats"]))).toBeUndefined()
  })
})
