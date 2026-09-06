import { describe, expect, it } from "vitest"
import { tabFromLocation } from "./queryKeys"

describe("tabFromLocation", () => {
  it("recognizes core tabs from the ?tab= query param", () => {
    expect(tabFromLocation("/jobs/1", "?tab=workflows")).toBe("workflows")
    expect(tabFromLocation("/jobs/1", "?tab=attachments")).toBe("attachments")
  })

  it("prioritizes the /source path suffix over the query param", () => {
    expect(tabFromLocation("/jobs/1/source", "?tab=workflows")).toBe("source")
  })

  it("defaults to summary with no ?tab= param", () => {
    expect(tabFromLocation("/jobs/1", "")).toBe("summary")
  })

  it("falls back to summary for an unrecognized tab key when no plugin tab claims it", () => {
    expect(tabFromLocation("/jobs/1", "?tab=coverage")).toBe("summary")
  })

  it("accepts a plugin-contributed tab key that isn't in the core tab list", () => {
    expect(tabFromLocation("/jobs/1", "?tab=coverage", ["coverage"])).toBe("coverage")
  })

  it("still falls back to summary when the requested key doesn't match any known plugin tab", () => {
    expect(tabFromLocation("/jobs/1", "?tab=coverage", ["tests"])).toBe("summary")
  })
})
