import { fireEvent, render, screen, within } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import readFileToolCard, { examples } from "./read_file"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return { toolName: "read_file", resultBody: "", resultError: false, parsedResult: null, ...overrides }
}

describe("read_file tool card", () => {
  it("registers under the normalized MCP tool name and supplies catalog examples", () => {
    expect(readFileToolCard.toolName).toBe("read_file")
    expect(examples.map((example) => example.id)).toEqual(["markdown", "paged_text", "read_error"])
  })

  it("summarizes the collapsed row with a line count", () => {
    expect(readFileToolCard.collapsedSummary?.(context({ parsedResult: { content: "line1\nline2\nline3" } }))).toBe("Read file (3 lines)")
  })

  it("renders markdown files with linked URLs, slug links, copyable paths, and a full-content modal", () => {
    const content = `${"Intro https://example.test/docs JOB-42.\n".repeat(40)}# Complete ending`
    render(<>{readFileToolCard.renderExpanded(context({ parsedResult: { content }, input: { path: "README.md", path_url: "/files/README.md" } }))}</>)

    expect(screen.getByRole("link", { name: "README.md" })).toHaveAttribute("href", "/files/README.md")
    expect(screen.getByRole("button", { name: "Copy README.md to clipboard" })).toBeInTheDocument()
    expect(screen.getAllByRole("link", { name: /https:\/\/example.test\/docs/ }).length).toBeGreaterThan(0)
    fireEvent.click(screen.getByRole("button", { name: "Show more" }))
    const dialog = screen.getByRole("dialog", { name: "Full contents of README.md" })
    expect(within(dialog).getByRole("heading", { name: "Complete ending" })).toBeInTheDocument()
    expect(within(dialog).getByRole("button", { name: "Copy markdown" })).toBeInTheDocument()
  })

  it("renders text through the code preview and opens the full file", () => {
    const content = Array.from({ length: 500 }, (_, i) => `line ${i}`).join("\n")
    render(<>{readFileToolCard.renderExpanded(context({ parsedResult: { content }, input: { path: "app/models/job.rb" } }))}</>)
    const previewCode = document.querySelector("code")
    expect(previewCode).toHaveTextContent("line 0")
    expect(previewCode).not.toHaveTextContent("line 499")
    fireEvent.click(screen.getByRole("button", { name: "Show more" }))
    expect(screen.getByRole("dialog").querySelector("code")).toHaveTextContent("line 499")
  })

  it("shows range and total metadata from a wrapped result envelope", () => {
    render(
      <>
        {readFileToolCard.renderExpanded(
          context({
            input: { path: "notes.txt", offset: 10, limit: 20 },
            parsedResult: { result: { content: "one\ntwo", total_lines: 80, total_bytes: 1234 } }
          })
        )}
      </>
    )
    expect(screen.getByText("10")).toBeInTheDocument()
    expect(screen.getByText("20")).toBeInTheDocument()
    expect(screen.getByText("80")).toBeInTheDocument()
    expect(screen.getByText(/1,234 bytes/)).toBeInTheDocument()
  })

  it("renders explicit and transport errors", () => {
    const { rerender } = render(
      <>{readFileToolCard.renderExpanded(context({ parsedResult: { error: "path escapes repository root" }, input: { path: "../secret" } }))}</>
    )
    expect(screen.getByText("path escapes repository root")).toBeInTheDocument()
    expect(readFileToolCard.collapsedSummary?.(context({ parsedResult: { error: "missing" } }))).toBe("File read failed")
    rerender(<>{readFileToolCard.renderExpanded(context({ resultError: true, resultBody: "Local daemon not connected.", parsedResult: null }))}</>)
    expect(screen.getByText("Local daemon not connected.")).toBeInTheDocument()
  })

  it("renders pending and empty states", () => {
    const { rerender } = render(<>{readFileToolCard.renderExpanded(context({ parsedResult: { state: "pending" } }))}</>)
    expect(screen.getByText("pending")).toBeInTheDocument()
    rerender(<>{readFileToolCard.renderExpanded(context({ parsedResult: { content: "" } }))}</>)
    expect(screen.getByText("Empty file.")).toBeInTheDocument()
  })

  it("falls back to null for a malformed payload", () => {
    expect(readFileToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(readFileToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
