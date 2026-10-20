import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import { normalizedToolCardParsedResult, normalizedToolName } from "@app/routes/chat/toolRendering"
import deleteMemoryToolCard from "./delete_memory"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "delete_memory",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

describe("delete_memory tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(deleteMemoryToolCard.toolName).toBe("delete_memory")
    expect(normalizedToolName("mcp__syrus__delete_memory")).toBe(deleteMemoryToolCard.toolName)
  })

  it("summarizes the collapsed row with a deletion confirmation", () => {
    expect(deleteMemoryToolCard.collapsedSummary?.(context({ parsedResult: { id: 9, deleted: true } }))).toBe("Deleted memory #9")
  })

  it("renders all input and result fields as responsive linked references and a state pill", () => {
    render(<>{deleteMemoryToolCard.renderExpanded(context({ input: { id: 8 }, parsedResult: { id: 9, deleted: true } }))}</>)

    expect(screen.getByText("Requested memory ID")).toBeInTheDocument()
    expect(screen.getByText("Memory ID")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: /MEMORY-8/ })).toHaveAttribute("href", "/memories")
    expect(screen.getByRole("link", { name: /MEMORY-9/ })).toHaveAttribute("href", "/memories")
    expect(screen.getByText("deleted")).toBeInTheDocument()
  })

  it("renders the not-deleted result state", () => {
    const toolContext = context({ parsedResult: { id: 9, deleted: false } })
    expect(deleteMemoryToolCard.collapsedSummary?.(toolContext)).toBe("Memory #9 was not deleted")
    render(<>{deleteMemoryToolCard.renderExpanded(toolContext)}</>)
    expect(screen.getByText("not deleted")).toBeInTheDocument()
  })

  it("renders a styled not-found or inaccessible error and links its returned id", () => {
    const toolContext = context({ input: { id: 91 }, resultError: true, resultBody: "Error: memory not found or not accessible: 91" })
    expect(deleteMemoryToolCard.collapsedSummary?.(toolContext)).toContain("Memory deletion failed")
    render(<>{deleteMemoryToolCard.renderExpanded(toolContext)}</>)

    expect(screen.getByRole("alert")).toHaveTextContent("memory not found or not accessible")
    expect(screen.getByRole("alert")).toHaveClass("bg-danger-surface")
    expect(screen.getByRole("link", { name: /MEMORY-91/ })).toHaveAttribute("href", "/memories")
    expect(screen.getByRole("link", { name: "91" })).toHaveAttribute("href", "/memories")
  })

  it("renders pending and empty states", () => {
    const pending = context({ input: { id: 9 } })
    expect(deleteMemoryToolCard.collapsedSummary?.(pending)).toBe("Deleting memory...")
    const { rerender } = render(<>{deleteMemoryToolCard.renderExpanded(pending)}</>)
    expect(screen.getByText("Deleting memory...")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: /MEMORY-9/ })).toBeInTheDocument()

    const empty = context({ input: { id: 9 }, parsedResult: {} })
    rerender(<>{deleteMemoryToolCard.renderExpanded(empty)}</>)
    expect(screen.getByText("No deletion result returned.")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: /MEMORY-9/ })).toBeInTheDocument()
  })

  it("accepts provider-agnostic structured and text MCP envelopes", () => {
    const payload = { id: 9, deleted: true }
    for (const parsedResult of [
      payload,
      normalizedToolCardParsedResult({ structured_content: payload }),
      normalizedToolCardParsedResult({ content: [{ type: "text", text: JSON.stringify(payload) }] })
    ]) {
      expect(deleteMemoryToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("Deleted memory #9")
    }
  })

  it("renders text-envelope errors and leaves unrelated scalar payloads to the generic card", () => {
    const envelope = { content: [{ type: "text", text: "Error: memory not found or not accessible: 12" }], structured_content: null }
    render(<>{deleteMemoryToolCard.renderExpanded(context({ parsedResult: envelope, resultError: true }))}</>)
    expect(screen.getByRole("alert")).toHaveTextContent("not accessible: 12")

    expect(deleteMemoryToolCard.collapsedSummary?.(context({ parsedResult: "not json", resultBody: "not json" }))).toBeNull()
    expect(deleteMemoryToolCard.renderExpanded(context({ parsedResult: "not json", resultBody: "not json" }))).toBeNull()
  })
})
