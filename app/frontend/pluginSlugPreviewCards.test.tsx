import { describe, expect, it } from "vitest"
import { pluginSlugPreviewCardComponentForPrefix, pluginSlugPreviewCardPrefixes } from "./pluginSlugPreviewCards"
import { registerPluginContribution } from "./pluginContributionRegistry"

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

  it("returns a slug preview card registered at runtime", () => {
    registerPluginContribution("slug_preview_card", "runtime_slug", "RUNTIME.PreviewCard", async () => ({ default: () => null }))

    expect(pluginSlugPreviewCardPrefixes()).toContain("RUNTIME")
    expect(pluginSlugPreviewCardComponentForPrefix("RUNTIME")).toBeTruthy()
  })
})
