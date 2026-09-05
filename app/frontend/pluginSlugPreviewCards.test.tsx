import { describe, expect, it } from "vitest"
import { pluginSlugPreviewCardComponentFor, pluginSlugPreviewCardComponentKeys } from "./pluginSlugPreviewCards"

describe("plugin slug preview card registry", () => {
  it("discovers installed plugin slug preview card components by component key", () => {
    expect(pluginSlugPreviewCardComponentKeys()).toContain("design_docs/DesignDocPreviewCard")
    expect(pluginSlugPreviewCardComponentFor("design_docs/DesignDocPreviewCard")).toBeTruthy()
    expect(pluginSlugPreviewCardComponentFor("missing/Nope")).toBeNull()
  })

  it("returns null for a nullish key", () => {
    expect(pluginSlugPreviewCardComponentFor(null)).toBeNull()
    expect(pluginSlugPreviewCardComponentFor(undefined)).toBeNull()
  })
})
