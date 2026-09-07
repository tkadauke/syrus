import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import deleteProposalToolCard from "./delete_proposal"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return { toolName: "delete_proposal", resultBody: "", resultError: false, parsedResult: null, ...overrides }
}

describe("delete_proposal tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(deleteProposalToolCard.toolName).toBe("delete_proposal")
  })

  it("summarizes a plain withdrawal with no cascade", () => {
    const parsedResult = { slug: "fix-output", state: "withdrawn", cascade: [] }
    expect(deleteProposalToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("Withdrew fix-output")
  })

  it("summarizes a withdrawal that cascades to downstream proposals", () => {
    const parsedResult = {
      slug: "fix-output",
      state: "withdrawn",
      cascade: [{ slug: "depends-on-fix-output", state: "withdrawn", kind: "job" }]
    }
    expect(deleteProposalToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("Withdrew fix-output and 1 downstream proposal")
  })

  it("renders the withdrawn slug and each cascaded slug", () => {
    const parsedResult = {
      slug: "fix-output",
      state: "withdrawn",
      cascade: [{ slug: "depends-on-fix-output", state: "withdrawn", kind: "job" }]
    }

    render(<>{deleteProposalToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("withdrawn")).toBeInTheDocument()
    expect(screen.getByText("fix-output")).toBeInTheDocument()
    expect(screen.getByText("depends-on-fix-output")).toBeInTheDocument()
  })

  it("omits the cascade section when nothing else was withdrawn", () => {
    const parsedResult = { slug: "fix-output", state: "withdrawn", cascade: [] }

    render(<>{deleteProposalToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.queryByText(/Also withdrawn/)).not.toBeInTheDocument()
  })

  it("falls back to null for a malformed payload", () => {
    const parsedResult = { oops: true }
    expect(deleteProposalToolCard.collapsedSummary?.(context({ parsedResult }))).toBeNull()
    expect(deleteProposalToolCard.renderExpanded(context({ parsedResult }))).toBeNull()
  })

  it("falls back to null for a non-object payload", () => {
    const parsedResult = "not json"
    expect(deleteProposalToolCard.collapsedSummary?.(context({ parsedResult }))).toBeNull()
    expect(deleteProposalToolCard.renderExpanded(context({ parsedResult }))).toBeNull()
  })
})
