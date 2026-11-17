import { render, screen, waitFor } from "@testing-library/react"
import { beforeAll, describe, expect, it, vi } from "vitest"
import { loadPluginModule } from "./i18n"
import { matchingReviewContribution, renderReviewContribution, reviewContributionComponentFor, type ReviewContribution } from "./pluginReviewContributions"
import { registerPluginContribution } from "./pluginContributionRegistry"

vi.mock("./i18n", async (importOriginal) => {
  const actual = await importOriginal<typeof import("./i18n")>()
  return { ...actual, loadPluginModule: vi.fn(actual.loadPluginModule) }
})

beforeAll(async () => {
  await import("./builtInPluginContributions")
})

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

  it("returns a review contribution registered at runtime", () => {
    registerPluginContribution("review_contribution", "runtime_review", "RuntimeEvidence", async () => ({ default: () => null }))

    expect(reviewContributionComponentFor("runtime_review/RuntimeEvidence")).toBeTruthy()
  })

  it("loads plugin locales with a runtime review contribution", async () => {
    vi.mocked(loadPluginModule).mockClear()
    registerPluginContribution("review_contribution", "localized_review", "Evidence", async () => ({ default: () => <span>Localized evidence</span> }))
    const contribution: ReviewContribution = {
      key: "localized.evidence",
      component: "localized_review/Evidence",
      kind: "evidence"
    }

    render(renderReviewContribution(contribution, {}))

    expect(await screen.findByText("Localized evidence")).toBeInTheDocument()
    await waitFor(() => expect(loadPluginModule).toHaveBeenCalledWith("localized_review", expect.any(Function)))
  })
})
