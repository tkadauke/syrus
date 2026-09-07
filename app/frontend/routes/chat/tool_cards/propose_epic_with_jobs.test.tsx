import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import proposeEpicWithJobsToolCard from "./propose_epic_with_jobs"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return { toolName: "propose_epic_with_jobs", resultBody: "", resultError: false, parsedResult: null, ...overrides }
}

describe("propose_epic_with_jobs tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(proposeEpicWithJobsToolCard.toolName).toBe("propose_epic_with_jobs")
  })

  it("summarizes the epic slug, state, and bundled Job count", () => {
    const parsedResult = {
      slug: "tier-2-cards",
      state: "proposed",
      kind: "epic",
      child_jobs: [
        { slug: "core-proposal-cards", state: "proposed" },
        { slug: "core-schedule-cards", state: "proposed" }
      ]
    }

    expect(proposeEpicWithJobsToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("Epic proposal: tier-2-cards (proposed, 2 Jobs)")
  })

  it("renders the target epic, dependency count, and each bundled child proposal", () => {
    const parsedResult = {
      slug: "tier-2-cards",
      state: "confirmed",
      kind: "epic",
      target_epic: { id: 292, number: 292, label: "EPIC-292" },
      depends_on_proposal_slugs: ["prep-work"],
      child_jobs: [
        { slug: "core-proposal-cards", state: "confirmed", target_repo: "tkadauke/syrus" },
        { slug: "core-schedule-cards", state: "proposed", target_repo: "tkadauke/syrus" }
      ]
    }

    render(<>{proposeEpicWithJobsToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("EPIC-292")).toBeInTheDocument()
    expect(screen.getByText("1 dependency")).toBeInTheDocument()
    expect(screen.getByText("core-proposal-cards")).toBeInTheDocument()
    expect(screen.getByText("core-schedule-cards")).toBeInTheDocument()
    expect(screen.getAllByText("confirmed").length).toBeGreaterThan(0)
    expect(screen.getByText("proposed")).toBeInTheDocument()
  })

  it("falls back to null for a malformed payload", () => {
    const parsedResult = { oops: true }
    expect(proposeEpicWithJobsToolCard.collapsedSummary?.(context({ parsedResult }))).toBeNull()
    expect(proposeEpicWithJobsToolCard.renderExpanded(context({ parsedResult }))).toBeNull()
  })

  it("falls back to null for a non-object payload", () => {
    const parsedResult = "not json"
    expect(proposeEpicWithJobsToolCard.collapsedSummary?.(context({ parsedResult }))).toBeNull()
    expect(proposeEpicWithJobsToolCard.renderExpanded(context({ parsedResult }))).toBeNull()
  })
})
