import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import closePreviewToolCard from "./close_preview"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "close_preview",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

describe("close_preview tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(closePreviewToolCard.toolName).toBe("close_preview")
  })

  it("summarizes the collapsed row with the closed state", () => {
    const parsedResult = { panel_id: "7", title: "Landing page", state: "closed" }
    expect(closePreviewToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("Landing page (closed)")
  })

  it("renders the closed panel details without a preview thumbnail or action", () => {
    const parsedResult = {
      panel_id: "7",
      title: "Landing page",
      state: "closed",
      url: "https://closed.example.test",
      file_count: 3,
      version_id: "12",
      entry_file: "index.html"
    }
    render(<>{closePreviewToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("Panel #7")).toBeInTheDocument()
    expect(screen.getByText("Closed")).toBeInTheDocument()
    expect(screen.getByText("Landing page")).toBeInTheDocument()
    expect(screen.getByText("index.html")).toBeInTheDocument()
    expect(screen.getByText("3")).toBeInTheDocument()
    expect(screen.getByText("12")).toBeInTheDocument()
    expect(screen.queryByTitle("Landing page thumbnail")).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Open Landing page" })).not.toBeInTheDocument()
    expect(screen.queryByRole("link", { name: "Open preview" })).not.toBeInTheDocument()
  })

  it("links the retained mockup when the result says it is reachable", () => {
    render(
      <>{closePreviewToolCard.renderExpanded(context({ parsedResult: { panel_id: "7", title: "Landing page", state: "closed", mockup_slug: "MOCKUP-7" } }))}</>
    )

    expect(screen.getByRole("link", { name: "Open mockup" })).toHaveAttribute("href", "/mockups/MOCKUP-7")
  })

  it("renders an empty result using input title and the closed state", () => {
    const parsedResult = { structured_content: { panel_id: "7", state: "closed", file_count: 0 } }
    render(<>{closePreviewToolCard.renderExpanded(context({ input: { panel_id: "7", title: "Input title" }, parsedResult }))}</>)

    expect(screen.getByText("Input title")).toBeInTheDocument()
    expect(screen.getByText("0")).toBeInTheDocument()
    expect(screen.queryByRole("link")).not.toBeInTheDocument()
  })

  it("normalizes text-block MCP envelopes", () => {
    const parsedResult = {
      content: [{ type: "text", text: JSON.stringify({ panel_id: "7", title: "Envelope title", state: "closed" }) }]
    }
    render(<>{closePreviewToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("Envelope title")).toBeInTheDocument()
    expect(screen.getByText("Closed")).toBeInTheDocument()
  })

  it("renders a styled panel-not-found error", () => {
    const failed = context({
      input: { panel_id: "99999", title: "Missing panel" },
      resultBody: 'Error: No open preview panel "99999" for this chat.',
      resultError: true
    })
    render(<>{closePreviewToolCard.renderExpanded(failed)}</>)

    expect(screen.getByText("Close preview")).toBeInTheDocument()
    expect(screen.getByText('No open preview panel "99999" for this chat.')).toBeInTheDocument()
    expect(closePreviewToolCard.collapsedSummary?.(failed)).toBe('Close preview failed: No open preview panel "99999" for this chat.')
  })

  it("falls back to null for a malformed payload", () => {
    expect(closePreviewToolCard.renderExpanded(context({ parsedResult: { oops: true } }))).toBeNull()
  })

  it("falls back to null for a non-object payload", () => {
    expect(closePreviewToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
