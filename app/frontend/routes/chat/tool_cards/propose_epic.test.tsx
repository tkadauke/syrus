import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import proposeEpicToolCard from "./propose_epic"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return { toolName: "propose_epic", resultBody: "", resultError: false, parsedResult: null, ...overrides }
}

describe("propose_epic tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(proposeEpicToolCard.toolName).toBe("propose_epic")
  })

  it("summarizes a proposed Epic", () => {
    const parsedResult = { slug: "tier-2-cards", title: "Tier 2 Custom Tool Cards", kind: "epic", state: "proposed" }
    expect(proposeEpicToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("Epic proposal: Tier 2 Custom Tool Cards (proposed)")
  })

  it("renders the materialized Epic and its child Job count once confirmed", () => {
    const parsedResult = {
      slug: "tier-2-cards",
      title: "Tier 2 Custom Tool Cards",
      kind: "epic",
      state: "confirmed",
      materialized: { kind: "epic", epic_id: 292, epic_title: "Tier 2 Custom Tool Cards", child_jobs: [{ job_id: 4222, title: "Add core cards" }] }
    }

    render(<>{proposeEpicToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("EPIC-292")).toBeInTheDocument()
    expect(screen.getByText(/1 child Job/)).toBeInTheDocument()
  })

  it("falls back to null for a malformed payload", () => {
    const parsedResult = { oops: true }
    expect(proposeEpicToolCard.collapsedSummary?.(context({ parsedResult }))).toBeNull()
    expect(proposeEpicToolCard.renderExpanded(context({ parsedResult }))).toBeNull()
  })
})
