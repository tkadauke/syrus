import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import { normalizedToolCardParsedResult, normalizedToolName } from "../toolRendering"
import deleteProposalToolCard, { examples } from "./delete_proposal"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return { toolName: normalizedToolName("mcp__syrus-chat-sidecar__delete_proposal"), resultBody: "", resultError: false, parsedResult: null, ...overrides }
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

  it.each([
    ["structured content", (payload: unknown) => ({ structured_content: payload })],
    ["text content", (payload: unknown) => ({ content: [{ type: "text", text: JSON.stringify(payload) }] })]
  ])("renders proposal references plus cascade titles, kinds, and states from normalized %s", (_label, envelope) => {
    const parsedResult = {
      slug: "fix-output",
      state: "withdrawn",
      cascade: [
        { slug: "depends-on-fix-output", title: "A dependent with a useful title", state: "withdrawn", kind: "job" },
        { slug: "a-very-long-dependent-proposal-slug-that-must-wrap-on-small-screens", title: "Dependent Epic", state: "rejected", kind: "epic" }
      ]
    }

    render(<>{deleteProposalToolCard.renderExpanded(context({ parsedResult: normalizedToolCardParsedResult(envelope(parsedResult)) }))}</>)

    expect(screen.getAllByText("withdrawn")).toHaveLength(2)
    expect(screen.getByText("fix-output")).toBeInTheDocument()
    expect(screen.getByText("depends-on-fix-output")).toBeInTheDocument()
    expect(screen.getByText("A dependent with a useful title")).toBeInTheDocument()
    expect(screen.getByText("a-very-long-dependent-proposal-slug-that-must-wrap-on-small-screens")).toHaveClass("break-all")
    expect(screen.getByText("Dependent Epic")).toBeInTheDocument()
    expect(screen.getByText("job")).toBeInTheDocument()
    expect(screen.getByText("epic")).toBeInTheDocument()
    expect(screen.getByText(/rejected/i)).toBeInTheDocument()
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

  it.each([
    ["unknown slug", "unknown proposal slug: missing-proposal"],
    ["withdrawn slug reuse", "slug has already been used by a withdrawn proposal"]
  ])("renders a styled failure card for %s errors", (_label, message) => {
    const envelope = { content: [{ type: "text", text: `Error: ${message}` }], structured_content: null }
    const cardContext = context({
      input: { slug: "missing-proposal" },
      parsedResult: normalizedToolCardParsedResult(envelope),
      resultBody: JSON.stringify(envelope),
      resultError: true
    })

    expect(deleteProposalToolCard.collapsedSummary?.(cardContext)).toContain(message)
    render(<>{deleteProposalToolCard.renderExpanded(cardContext)}</>)

    expect(screen.getByText("Proposal withdrawal failed")).toBeInTheDocument()
    expect(screen.getByText(message)).toBeInTheDocument()
    expect(screen.getByText("Withdraw proposal missing-proposal")).toBeInTheDocument()
    expect(screen.getByText("Check before retrying")).toBeInTheDocument()
  })

  it("exports catalog examples for cascade, empty, and error states", () => {
    expect(examples.map((example) => example.id)).toEqual(["cascade", "no_cascade", "unknown_slug"])
  })
})
