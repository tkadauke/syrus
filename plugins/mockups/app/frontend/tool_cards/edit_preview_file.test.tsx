import { fireEvent, render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import editPreviewFileToolCard from "./edit_preview_file"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "edit_preview_file",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

describe("edit_preview_file tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(editPreviewFileToolCard.toolName).toBe("edit_preview_file")
  })

  it("summarizes the collapsed row with the path and panel id", () => {
    const parsedResult = { panel_id: "7", path: "index.html", replacements: 2 }
    expect(editPreviewFileToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("Edited index.html (panel #7)")
  })

  it("renders all edit inputs and result fields with a panel reference", () => {
    const parsedResult = { panel_id: "7", path: "index.html", replacements: 2 }
    const { container } = render(
      <>
        {editPreviewFileToolCard.renderExpanded(
          context({
            input: { panel_id: "7", path: "index.html", old_string: "<h1>Old</h1>", new_string: "<h1>New</h1>", replace_all: false },
            parsedResult
          })
        )}
      </>
    )

    expect(screen.getByText("Edited file")).toBeInTheDocument()
    expect(screen.getByText("Panel #7")).toBeInTheDocument()
    expect(screen.getByText("index.html")).toBeInTheDocument()
    expect(screen.getByText("2")).toBeInTheDocument()
    expect(screen.getByText("No")).toBeInTheDocument()
    fireEvent.click(screen.getByText("Changes"))
    expect(container.textContent).toContain("<h1>Old</h1>")
    expect(container.textContent).toContain("<h1>New</h1>")
    expect(container.querySelector("details")?.parentElement).toHaveClass("overflow-hidden")
    expect(container.querySelector("details div.overflow-x-auto")).toBeInTheDocument()
  })

  it("shows replace_all and accepts a structured content result envelope", () => {
    const parsedResult = { structured_content: { panel_id: "7", path: "styles.css", replacements: 4 } }
    render(<>{editPreviewFileToolCard.renderExpanded(context({ input: { old_string: "#fff", new_string: "#000", replace_all: true }, parsedResult }))}</>)

    expect(screen.getByText("styles.css")).toBeInTheDocument()
    expect(screen.getByText("4")).toBeInTheDocument()
    expect(screen.getByText("Yes")).toBeInTheDocument()
  })

  it("accepts a provider text-content envelope", () => {
    const parsedResult = { content: [{ type: "text", text: JSON.stringify({ panel_id: "8", path: "app.js", replacements: 1 }) }] }
    render(<>{editPreviewFileToolCard.renderExpanded(context({ input: { old_string: "", new_string: "ready" }, parsedResult }))}</>)

    expect(screen.getByText("Panel #8")).toBeInTheDocument()
    expect(screen.getByText("app.js")).toBeInTheDocument()
  })

  it.each([
    ["multiple matches", { error: "old_string must appear exactly once; found 3 matches" }, false],
    ["not found", { structured_content: { error: "old_string was not found" } }, false],
    ["panel not found", null, true]
  ])("renders a styled %s error card", (_label, parsedResult, resultError) => {
    const resultBody = resultError ? "Error: Preview panel 99 was not found" : ""
    render(<>{editPreviewFileToolCard.renderExpanded(context({ parsedResult, resultBody, resultError }))}</>)

    expect(screen.getByText("Edit preview file")).toBeInTheDocument()
    expect(screen.getByText(/must appear exactly once|was not found|Preview panel 99 was not found/)).toBeInTheDocument()
  })

  it("falls back to null for a malformed payload (missing path)", () => {
    expect(editPreviewFileToolCard.renderExpanded(context({ parsedResult: { panel_id: "7" } }))).toBeNull()
  })

  it("falls back to null for a non-object payload", () => {
    expect(editPreviewFileToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
