import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import deleteElementToolCard, { examples } from "./delete_element"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "delete_element",
    input: { id: "shape-1" },
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

describe("delete_element tool card", () => {
  it("shows every success field and preserves responsive wrapping", () => {
    const toolContext = context({ parsedResult: { id: "shape-1", type: "diamond", label: "Decision", version: 12 } })
    expect(deleteElementToolCard.collapsedSummary?.(toolContext)).toBe("Deleted element (diamond) · shape-1")

    const { container } = render(<>{deleteElementToolCard.renderExpanded(toolContext)}</>)
    for (const value of ["Deleted element", "shape-1", "diamond", "Decision", "v12"]) expect(screen.getAllByText(value).length).toBeGreaterThan(0)
    expect(container.querySelector(".flex-wrap.min-w-0")).toBeInTheDocument()
    expect(screen.getAllByText("shape-1")[0]).toHaveClass("break-all")
    expect(container.querySelector(".sm\\:grid-cols-2")).toBeInTheDocument()
  })

  it("renders element-not-found as the shared failure card", () => {
    const toolContext = context({
      resultError: true,
      resultBody: "Element not found: shape-1",
      parsedResult: { error_class: "Whiteboard::Canvas::ElementNotFound", message: "Element not found: shape-1", retryable: false }
    })

    expect(deleteElementToolCard.collapsedSummary?.(toolContext)).toBe("Deleted element failed: Element not found: shape-1")
    render(<>{deleteElementToolCard.renderExpanded(toolContext)}</>)
    expect(screen.getByText("Deleted element failed")).toBeInTheDocument()
    expect(screen.getByText("Element not found: shape-1")).toBeInTheDocument()
    expect(screen.getByText("Check before retrying")).toBeInTheDocument()
    expect(screen.getByText("Whiteboard::Canvas::ElementNotFound")).toBeInTheDocument()
  })

  it("reads id, type, label, and version from a wrapped result envelope", () => {
    const toolContext = context({ input: { id: "text-2" }, parsedResult: { result: { id: "text-2", type: "text", label: "Roadmap", version: 13 } } })
    expect(deleteElementToolCard.collapsedSummary?.(toolContext)).toBe("Deleted element (text) · text-2")
    render(<>{deleteElementToolCard.renderExpanded(toolContext)}</>)
    for (const value of ["text-2", "text", "Roadmap", "v13"]) expect(screen.getAllByText(value).length).toBeGreaterThan(0)
  })

  it("covers pending and malformed empty results without provider-specific assumptions", () => {
    expect(deleteElementToolCard.collapsedSummary?.(context())).toBe("Deleted element pending")
    render(<>{deleteElementToolCard.renderExpanded(context())}</>)
    expect(screen.getByText("Waiting for a result")).toBeInTheDocument()
    expect(deleteElementToolCard.collapsedSummary?.(context({ parsedResult: {} }))).toBe("Deleted element returned no element")
    render(<>{deleteElementToolCard.renderExpanded(context({ parsedResult: {} }))}</>)
    expect(screen.getByText("Result did not include an element ID")).toBeInTheDocument()
    expect(examples.every((example) => example.sourceType === "generic")).toBe(true)
  })
})
