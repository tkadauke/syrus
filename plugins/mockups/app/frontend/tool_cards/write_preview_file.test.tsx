import { fireEvent, render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import { toolCardContextForExample, type ToolCardContext } from "@app/pluginToolCards"
import writePreviewFileToolCard, { examples } from "./write_preview_file"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "write_preview_file",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

describe("write_preview_file tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(writePreviewFileToolCard.toolName).toBe("write_preview_file")
  })

  it("summarizes the collapsed row with the path and panel id", () => {
    const parsedResult = { panel_id: "7", path: "index.html" }
    expect(writePreviewFileToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("Wrote index.html (panel #7)")
  })

  it("renders input and result details with a responsive layout and mockup link", () => {
    const parsedResult = { panel_id: "7", path: "index.html", size: 12, mockup_slug: "MOCKUP-7" }
    render(<>{writePreviewFileToolCard.renderExpanded(context({ chatSessionId: 8, input: { content: "hello\nworld" }, parsedResult }))}</>)

    expect(screen.getByText("Wrote file")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Panel #7" })).toHaveAttribute("href", "/chats/8?workspace=preview%3A7")
    expect(screen.getAllByText("index.html")).toHaveLength(2)
    expect(screen.getByText("12 bytes")).toBeInTheDocument()
    expect(screen.getByText("2")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Open mockup" })).toHaveAttribute("href", "/mockups/MOCKUP-7")
    expect(screen.getByText("Path").closest("dl")).toHaveClass("sm:grid-cols-2")
  })

  it("shows a code preview with UTF-8 input-derived size", () => {
    render(
      <>
        {writePreviewFileToolCard.renderExpanded(
          context({ input: { panel_id: "7", path: "app.js", content: "héllo" }, parsedResult: { panel_id: "7", path: "app.js" } })
        )}
      </>
    )
    expect(screen.getByText("6 bytes")).toBeInTheDocument()
    fireEvent.click(screen.getByText("Written content"))
    expect(screen.getByTestId("text-preview-content")).toHaveTextContent("héllo")
  })

  it("renders Markdown prose with slug and URL links plus Show more", () => {
    const content = `See JOB-42 and https://example.test/details.\n\n${"More prose. ".repeat(120)}`
    render(
      <>
        {writePreviewFileToolCard.renderExpanded(
          context({ input: { panel_id: "7", path: "notes.md", content }, parsedResult: { panel_id: "7", path: "notes.md" } })
        )}
      </>
    )
    fireEvent.click(screen.getByText("Written content"))
    expect(screen.getByTestId("markdown-preview-content")).toHaveTextContent("JOB-42")
    expect(screen.getByRole("link", { name: "https://example.test/details" })).toHaveAttribute("href", "https://example.test/details")
    expect(screen.getByRole("button", { name: "Show more" })).toBeInTheDocument()
  })

  it("shows an explicit empty state for blank content", () => {
    render(
      <>
        {writePreviewFileToolCard.renderExpanded(
          context({ input: { panel_id: "7", path: "empty.txt", content: "" }, parsedResult: { panel_id: "7", path: "empty.txt" } })
        )}
      </>
    )
    expect(screen.getByText("0 bytes")).toBeInTheDocument()
    expect(screen.getByText("0")).toBeInTheDocument()
    fireEvent.click(screen.getByText("Written content"))
    expect(screen.getByText("The file is empty.")).toBeInTheDocument()
  })

  it("shows transport and structured errors as styled cards", () => {
    render(<>{writePreviewFileToolCard.renderExpanded(context({ resultError: true, resultBody: "Error: panel not found" }))}</>)
    expect(screen.getByText("Write preview file")).toBeInTheDocument()
    expect(screen.getByText("panel not found")).toBeInTheDocument()

    render(<>{writePreviewFileToolCard.renderExpanded(context({ parsedResult: { error: "path is required" } }))}</>)
    expect(screen.getByText("path is required")).toBeInTheDocument()
    expect(writePreviewFileToolCard.collapsedSummary?.(context({ parsedResult: { error: "path is required" } }))).toBe(
      "Write preview file failed: path is required"
    )
  })

  it("marks the structured panel error catalog example as failed", () => {
    expect(examples.find((example) => example.id === "panel_not_found")?.resultError).toBe(true)
  })

  it("keeps the panel reference linked in the catalog example", () => {
    const example = examples.find((candidate) => candidate.id === "markdown_file")!
    render(<>{writePreviewFileToolCard.renderExpanded(toolCardContextForExample(writePreviewFileToolCard.toolName, example))}</>)

    expect(screen.getByRole("link", { name: "Panel #42" })).toHaveAttribute("href", "/chats/8?workspace=preview%3A42")
  })

  it.each([
    { structured_content: { panel_id: "7", path: "styles.css" } },
    { content: [{ type: "text", text: JSON.stringify({ panel_id: "7", path: "styles.css" }) }] }
  ])("renders provider-agnostic result envelopes", (parsedResult) => {
    render(<>{writePreviewFileToolCard.renderExpanded(context({ input: { content: "body {}" }, parsedResult }))}</>)
    expect(screen.getAllByText("styles.css")).toHaveLength(2)
    expect(screen.getByText("7 bytes")).toBeInTheDocument()
  })

  it("falls back to null for a malformed payload (missing path)", () => {
    expect(writePreviewFileToolCard.renderExpanded(context({ parsedResult: { panel_id: "7" } }))).toBeNull()
  })

  it("falls back to null for a non-object payload", () => {
    expect(writePreviewFileToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
