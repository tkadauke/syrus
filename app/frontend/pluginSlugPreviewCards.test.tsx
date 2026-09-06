import { describe, expect, it } from "vitest"
import { pluginSlugPreviewCardComponentForPrefix, pluginSlugPreviewCardPrefixes } from "./pluginSlugPreviewCards"

describe("plugin slug preview card registry", () => {
  it("discovers installed plugin slug preview card components by slug prefix", () => {
    expect(pluginSlugPreviewCardPrefixes()).toContain("DOC")
    expect(pluginSlugPreviewCardComponentForPrefix("DOC")).toBeTruthy()
    expect(pluginSlugPreviewCardComponentForPrefix("MISSING")).toBeNull()
  })

  it("returns null for a nullish prefix", () => {
    expect(pluginSlugPreviewCardComponentForPrefix(null)).toBeNull()
    expect(pluginSlugPreviewCardComponentForPrefix(undefined)).toBeNull()
  })
})
