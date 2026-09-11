import { fireEvent, render, screen, within } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import showPreviewToolCard from "./show_preview"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "show_preview",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

describe("show_preview tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(showPreviewToolCard.toolName).toBe("show_preview")
  })

  it("summarizes the collapsed row with the panel title and state", () => {
    const parsedResult = { panel_id: "7", title: "Landing page", state: "open", entry_file: "index.html" }
    expect(showPreviewToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("Landing page (open)")
  })

  it("renders panel id, entry file, file count, and a mockup link when published", () => {
    const parsedResult = {
      panel_id: "7",
      title: "Landing page",
      state: "open",
      file_count: 3,
      version_id: "12",
      entry_file: "index.html",
      mockup_slug: "abc123"
    }

    render(<>{showPreviewToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("Panel #7")).toBeInTheDocument()
    expect(screen.getAllByText("open").length).toBeGreaterThan(0)
    expect(screen.getAllByText("Landing page").length).toBeGreaterThan(0)
    expect(screen.getAllByText("index.html").length).toBeGreaterThan(0)
    expect(screen.getByText("3")).toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: "Open Landing page" }))
    const dialog = screen.getByRole("dialog", { name: "Landing page" })
    const link = within(dialog).getByRole("link", { name: "Open mockup" })
    expect(link).toHaveAttribute("href", "/mockups/abc123")
  })

  it("falls back to a raw url link when no mockup was published", () => {
    const parsedResult = { panel_id: "7", title: "Landing page", state: "open", url: "https://panel.example.test" }

    render(<>{showPreviewToolCard.renderExpanded(context({ parsedResult }))}</>)

    fireEvent.click(screen.getByRole("button", { name: "Open Landing page" }))
    expect(screen.getByRole("link", { name: "Open preview" })).toHaveAttribute(
      "href",
      "https://panel.example.test"
    )
  })

  it("falls back to null for a malformed payload (missing panel_id)", () => {
    expect(showPreviewToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(showPreviewToolCard.renderExpanded(context({ parsedResult: { oops: true } }))).toBeNull()
  })

  it("falls back to null for a non-object payload", () => {
    expect(showPreviewToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
