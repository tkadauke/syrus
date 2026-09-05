import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import listOpenPrsToolCard from "./list_open_prs"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "list_open_prs",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

describe("list_open_prs tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(listOpenPrsToolCard.toolName).toBe("list_open_prs")
  })

  it("summarizes the collapsed row with a count", () => {
    const parsedResult = { pull_requests: [{ number: 1 }, { number: 2 }] }
    expect(listOpenPrsToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("2 pull requests")
  })

  it("renders title, refs, draft, and mergeability per row", () => {
    const parsedResult = {
      pull_requests: [
        { number: 7, title: "Add tool cards", head_ref: "syrus/direct-4221", base_ref: "main", mergeable: true, draft: false },
        { number: 8, title: "WIP", head_ref: "syrus/direct-4300", base_ref: "main", mergeable: false, draft: true },
        { number: 9, title: "Pending check", head_ref: "syrus/direct-4301", base_ref: "main", mergeable: null, draft: false }
      ]
    }

    render(<>{listOpenPrsToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("#7")).toBeInTheDocument()
    expect(screen.getByText("Add tool cards")).toBeInTheDocument()
    expect(screen.getByText("syrus/direct-4221 → main")).toBeInTheDocument()
    expect(screen.getByText("mergeable")).toBeInTheDocument()
    expect(screen.getByText("conflicts")).toBeInTheDocument()
    expect(screen.getByText("checking")).toBeInTheDocument()
    expect(screen.getByText("draft")).toBeInTheDocument()
  })

  it("renders an explicit empty state for a well-formed empty list", () => {
    render(<>{listOpenPrsToolCard.renderExpanded(context({ parsedResult: { pull_requests: [] } }))}</>)
    expect(screen.getByText("No pull requests found.")).toBeInTheDocument()
  })

  it("falls back to null for a malformed payload", () => {
    expect(listOpenPrsToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(listOpenPrsToolCard.renderExpanded(context({ parsedResult: { oops: true } }))).toBeNull()
  })

  it("falls back to null for a non-object payload", () => {
    expect(listOpenPrsToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
