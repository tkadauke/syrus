import { fireEvent, render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import { normalizedToolCardParsedResult, normalizedToolName } from "@app/routes/chat/toolRendering"
import unpublishMemoryToolCard, { examples } from "./unpublish_memory"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "unpublish_memory",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

const memory = {
  id: "21",
  kind: "decision",
  scope: "repository",
  scope_id: "3",
  content: `Withdraw the **rollout**. See https://example.com/runbook. ${"More private context. ".repeat(30)}`,
  published: false,
  author: "Operator",
  confidence: 0.85,
  expires_at: "2027-01-01T00:00:00Z",
  last_verified_at: "2026-09-02T00:00:00Z",
  created_at: "2026-08-31T00:00:00Z",
  updated_at: "2026-09-01T00:00:00Z"
}

describe("unpublish_memory tool card", () => {
  it("registers under the normalized MCP tool name and supplies catalog states", () => {
    expect(unpublishMemoryToolCard.toolName).toBe("unpublish_memory")
    expect(normalizedToolName("mcp__syrus__unpublish_memory")).toBe(unpublishMemoryToolCard.toolName)
    expect(examples.map((example) => example.id)).toEqual(["repository_memory_unpublished", "not_owned", "pending"])
  })

  it("summarizes the collapsed row as an unpublish confirmation", () => {
    expect(unpublishMemoryToolCard.collapsedSummary?.(context({ parsedResult: { memory } }))).toBe("Unpublished memory #21")
  })

  it("renders input, state change, returned fields, links, and responsive wrapping", () => {
    const { container } = render(<>{unpublishMemoryToolCard.renderExpanded(context({ input: { memory_id: 21 }, parsedResult: { memory } }))}</>)

    expect(screen.getByText("published")).toBeInTheDocument()
    expect(screen.getAllByText("private")).toHaveLength(2)
    expect(screen.getByText("Requested memory ID")).toBeInTheDocument()
    expect(screen.getAllByRole("link", { name: /MEMORY-21/ })).toHaveLength(2)
    expect(screen.getByRole("link", { name: /repository #3/i })).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "https://example.com/runbook" })).toHaveAttribute("href", "https://example.com/runbook")
    expect(screen.getByText("Operator")).toBeInTheDocument()
    expect(screen.getByText("0.85")).toBeInTheDocument()
    expect(screen.getByText("2027-01-01T00:00:00Z")).toBeInTheDocument()
    expect(screen.getByText("2026-09-02T00:00:00Z")).toBeInTheDocument()
    expect(screen.getByText("2026-08-31T00:00:00Z")).toBeInTheDocument()
    expect(screen.getByText("2026-09-01T00:00:00Z")).toBeInTheDocument()
    expect(screen.queryByText("user_id")).not.toBeInTheDocument()
    expect(screen.queryByText("visibility")).not.toBeInTheDocument()
    expect(container.querySelector(".flex-wrap")).toBeInTheDocument()
    expect(container.querySelector(".sm\\:grid-cols-2")).toBeInTheDocument()
  })

  it("renders Markdown with a complete copyable modal", () => {
    render(<>{unpublishMemoryToolCard.renderExpanded(context({ parsedResult: { memory } }))}</>)

    expect(screen.getByText("rollout").tagName).toBe("STRONG")
    fireEvent.click(screen.getByRole("button", { name: "Show more" }))
    expect(screen.getByRole("dialog")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Copy memory content" })).toBeInTheDocument()
  })

  it("renders errors, pending, and blank-content states", () => {
    const failure = context({ resultBody: "Error: memory not found or not owned: 999", resultError: true })
    expect(unpublishMemoryToolCard.collapsedSummary?.(failure)).toContain("Memory unpublish failed")
    const { rerender } = render(<>{unpublishMemoryToolCard.renderExpanded(failure)}</>)
    expect(screen.getByRole("alert")).toHaveTextContent("memory not found or not owned: 999")

    const pending = context({ input: { memory_id: 21 } })
    expect(unpublishMemoryToolCard.collapsedSummary?.(pending)).toBe("Unpublishing memory...")
    rerender(<>{unpublishMemoryToolCard.renderExpanded(pending)}</>)
    expect(screen.getByText("Unpublishing memory...")).toBeInTheDocument()

    rerender(<>{unpublishMemoryToolCard.renderExpanded(context({ parsedResult: { memory: { ...memory, content: "" } } }))}</>)
    expect(screen.getByText("No memory content returned.")).toBeInTheDocument()
  })

  it("accepts provider-agnostic structured and text envelopes after normalization", () => {
    const payload = { memory }
    for (const envelope of [payload, { structured_content: payload }, { content: [{ type: "text", text: JSON.stringify(payload) }] }]) {
      const parsedResult = normalizedToolCardParsedResult(envelope)
      expect(unpublishMemoryToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("Unpublished memory #21")
    }
  })

  it("handles error envelopes and rejects malformed results", () => {
    const errorEnvelope = { content: [{ type: "text", text: "Error: validation failed" }], structured_content: null }
    render(<>{unpublishMemoryToolCard.renderExpanded(context({ parsedResult: errorEnvelope }))}</>)
    expect(screen.getByRole("alert")).toHaveTextContent("validation failed")

    for (const parsedResult of [{ oops: true }, "not json"]) {
      expect(unpublishMemoryToolCard.collapsedSummary?.(context({ parsedResult }))).toBeNull()
      expect(unpublishMemoryToolCard.renderExpanded(context({ parsedResult }))).toBeNull()
    }
  })
})
