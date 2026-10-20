import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import { normalizedToolCardParsedResult, normalizedToolName } from "@app/routes/chat/toolRendering"
import writeMemoryToolCard from "./write_memory"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "write_memory",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

const memory = {
  id: "55",
  kind: "feedback",
  scope: "global",
  scope_id: null,
  content: "Don't mock the database in integration tests.",
  published: false,
  expires_at: "2027-01-01T00:00:00Z",
  last_verified_at: "2026-09-06T14:00:00Z",
  created_at: "2026-09-04T14:00:00Z",
  updated_at: "2026-09-05T14:00:00Z"
}

describe("write_memory tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(writeMemoryToolCard.toolName).toBe("write_memory")
    expect(normalizedToolName("mcp__syrus__write_memory")).toBe(writeMemoryToolCard.toolName)
  })

  it("summarizes the collapsed row as a write confirmation", () => {
    expect(writeMemoryToolCard.collapsedSummary?.(context({ parsedResult: { id: "55", memory } }))).toBe("Wrote memory #55 (feedback)")
  })

  it("renders safe result fields, linked references, and write inputs", () => {
    render(
      <>
        {writeMemoryToolCard.renderExpanded(
          context({
            input: { scope: "repository", scope_id: "42", kind: "feedback" },
            parsedResult: { id: "55", memory: { ...memory, scope: "repository", scope_id: "42" } }
          })
        )}
      </>
    )

    expect(screen.getAllByText("feedback")).toHaveLength(2)
    expect(screen.getByText("Don't mock the database in integration tests.")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: /MEMORY-55/ })).toHaveAttribute("href", "/memories")
    expect(screen.getAllByRole("link", { name: /repository #42/i })).toHaveLength(2)
    expect(screen.getByText("Requested scope")).toBeInTheDocument()
    expect(screen.getByText("Requested repository ID")).toBeInTheDocument()
    expect(screen.getByText("Expires")).toBeInTheDocument()
    expect(screen.getByText("2027-01-01T00:00:00Z")).toBeInTheDocument()
    expect(screen.getByText("Last verified")).toBeInTheDocument()
    expect(screen.getByText("Created")).toBeInTheDocument()
    expect(screen.queryByText("user_id")).not.toBeInTheDocument()
    expect(screen.queryByText("visibility")).not.toBeInTheDocument()
  })

  it("renders plain and duplicate errors, linking the existing memory", () => {
    const duplicate = context({
      resultError: true,
      resultBody: "Error: similar feedback memory already exists as memory #91; read_memory that id instead"
    })
    expect(writeMemoryToolCard.collapsedSummary?.(duplicate)).toContain("Memory write failed")
    const { rerender } = render(<>{writeMemoryToolCard.renderExpanded(duplicate)}</>)
    expect(screen.getByRole("alert")).toHaveTextContent("similar feedback memory")
    expect(screen.getByRole("link", { name: /memory #91/i })).toHaveAttribute("href", "/memories")

    const envelope = {
      content: [{ type: "text", text: "Error: content is required" }],
      structured_content: null
    }
    rerender(<>{writeMemoryToolCard.renderExpanded(context({ parsedResult: envelope }))}</>)
    expect(screen.getByRole("alert")).toHaveTextContent("content is required")
  })

  it("does not classify a successful plain-text MCP envelope as a memory error", () => {
    const envelope = { content: [{ type: "text", text: "Memory service accepted the request." }], structured_content: null }
    const toolContext = context({ parsedResult: envelope, resultBody: JSON.stringify(envelope) })

    expect(writeMemoryToolCard.collapsedSummary?.(toolContext)).toBeNull()
    expect(writeMemoryToolCard.renderExpanded(toolContext)).toBeNull()
  })

  it("renders pending and blank-content states", () => {
    const pending = context()
    expect(writeMemoryToolCard.collapsedSummary?.(pending)).toBe("Writing memory...")
    const { rerender } = render(<>{writeMemoryToolCard.renderExpanded(pending)}</>)
    expect(screen.getByText("Writing memory...")).toBeInTheDocument()

    rerender(<>{writeMemoryToolCard.renderExpanded(context({ parsedResult: { memory: { ...memory, content: "" } } }))}</>)
    expect(screen.getByText("No memory content returned.")).toBeInTheDocument()
  })

  it("accepts normalized structured and text MCP envelopes", () => {
    const payload = { id: "55", memory }
    for (const parsedResult of [payload, { structured_content: payload }, { content: [{ type: "text", text: JSON.stringify(payload) }] }]) {
      const normalized = normalizedToolCardParsedResult(parsedResult)
      expect(writeMemoryToolCard.collapsedSummary?.(context({ parsedResult: normalized }))).toBe("Wrote memory #55 (feedback)")
    }
  })

  it("falls back to null for a malformed payload", () => {
    const parsedResult = { oops: true }

    expect(writeMemoryToolCard.collapsedSummary?.(context({ parsedResult }))).toBeNull()
    expect(writeMemoryToolCard.renderExpanded(context({ parsedResult }))).toBeNull()
  })

  it("falls back to null for a non-object payload", () => {
    const parsedResult = "not json"

    expect(writeMemoryToolCard.collapsedSummary?.(context({ parsedResult }))).toBeNull()
    expect(writeMemoryToolCard.renderExpanded(context({ parsedResult }))).toBeNull()
  })
})
