import { describe, expect, it } from "vitest"
import { registerPluginContribution } from "./pluginContributionRegistry"
import { pluginReviewAnnotationComponentFor, pluginReviewAnnotationComponentKeys } from "./pluginReviewAnnotations"

describe("plugin review annotation registry", () => {
  it("discovers installed plugin review annotation components", () => {
    expect(pluginReviewAnnotationComponentKeys).toContain("cognitive_review/note_panel")
    expect(pluginReviewAnnotationComponentFor("cognitive_review/note_panel")).toBeTruthy()
    expect(pluginReviewAnnotationComponentFor("missing/Nope")).toBeNull()
  })

  it("returns a review annotation registered at runtime", () => {
    registerPluginContribution("review_annotation", "runtime_annotation", "RuntimeNote", async () => ({ default: () => null }))

    expect(pluginReviewAnnotationComponentFor("runtime_annotation/RuntimeNote")).toBeTruthy()
  })
})
