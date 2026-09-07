import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import listProposalsToolCard from "./list_proposals"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return { toolName: "list_proposals", resultBody: "", resultError: false, parsedResult: null, ...overrides }
}

describe("list_proposals tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(listProposalsToolCard.toolName).toBe("list_proposals")
  })

  it("summarizes the proposal count", () => {
    const parsedResult = { proposals: [{ slug: "a", state: "proposed", kind: "job" }, { slug: "b", state: "confirmed", kind: "epic" }] }
    expect(listProposalsToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("2 proposals")
  })

  it("renders a friendly empty state for a well-formed empty list", () => {
    const parsedResult = { proposals: [] }
    expect(listProposalsToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("0 proposals")

    render(<>{listProposalsToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("No proposals in this chat yet.")).toBeInTheDocument()
  })

  it("renders every proposal's slug, kind, state, and title", () => {
    const parsedResult = {
      proposals: [
        { slug: "fix-output", title: "Fix output", kind: "job", state: "proposed" },
        { slug: "tier-2-cards", title: "Tier 2 Custom Tool Cards", kind: "epic", state: "withdrawn" }
      ]
    }

    render(<>{listProposalsToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByRole("table")).toBeInTheDocument()
    expect(screen.getByText("fix-output")).toBeInTheDocument()
    expect(screen.getByText("Fix output")).toBeInTheDocument()
    expect(screen.getByText("proposed")).toBeInTheDocument()
    expect(screen.getByText("tier-2-cards")).toBeInTheDocument()
    expect(screen.getByText("Tier 2 Custom Tool Cards")).toBeInTheDocument()
    expect(screen.getByText("withdrawn")).toBeInTheDocument()
  })

  it("falls back to null for a malformed payload", () => {
    const parsedResult = { oops: true }
    expect(listProposalsToolCard.collapsedSummary?.(context({ parsedResult }))).toBeNull()
    expect(listProposalsToolCard.renderExpanded(context({ parsedResult }))).toBeNull()
  })

  it("falls back to null for a non-object payload", () => {
    const parsedResult = "not json"
    expect(listProposalsToolCard.collapsedSummary?.(context({ parsedResult }))).toBeNull()
    expect(listProposalsToolCard.renderExpanded(context({ parsedResult }))).toBeNull()
  })
})
