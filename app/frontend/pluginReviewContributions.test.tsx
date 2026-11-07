import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import { matchingReviewContribution, renderReviewContribution, reviewContributionComponentFor, type ReviewContribution } from "./pluginReviewContributions"

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

  it("loads and renders an installed plugin contribution through Suspense", async () => {
    const contribution: ReviewContribution = {
      key: "synthetic.evidence",
      component: "syrus_dev/SyntheticReview",
      kind: "evidence",
      target_type: "synthetic",
      aria_label_key: "Synthetic review evidence"
    }
    render(renderReviewContribution(contribution, { label: "Synthetic evidence rendered" }))
    expect(await screen.findByLabelText("Synthetic review evidence")).toHaveTextContent("Synthetic evidence rendered")
  })
})
