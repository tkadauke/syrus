import { describe, expect, it } from "vitest"
import { matchingReviewContribution, reviewContributionComponentFor, type ReviewContribution } from "./pluginReviewContributions"

describe("plugin review contributions", () => {
  const entries: ReviewContribution[] = [
    { key: "sample.target", component: "sample/Target", kind: "target_editor", target_type: "sample" },
    { key: "sample.audit", component: "sample/Audit", kind: "audit" }
  ]

  it("selects opaque target editors without branching on a plugin target type", () => {
    expect(matchingReviewContribution(entries, "target_editor", { targetType: "sample" })?.key).toBe("sample.target")
  })

  it("falls back safely for a component from an absent or history-only plugin", () => {
    expect(reviewContributionComponentFor("removed/HistoryRenderer")).toBeNull()
  })
})
