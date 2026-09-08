import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import listFilesToolCard from "./list_files"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return { toolName: "list_files", resultBody: "", resultError: false, parsedResult: null, ...overrides }
}

describe("list_files tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(listFilesToolCard.toolName).toBe("list_files")
  })

  it("summarizes the collapsed row with an item count", () => {
    const parsedResult = { files: [{ name: "app", is_dir: true }, { name: "README.md", is_dir: false }] }
    expect(listFilesToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("2 items")
  })

  it("renders directories before files, both sorted alphabetically", () => {
    const parsedResult = {
      files: [
        { name: "README.md", is_dir: false },
        { name: "config", is_dir: true },
        { name: "app", is_dir: true }
      ]
    }

    render(<>{listFilesToolCard.renderExpanded(context({ parsedResult, input: { path: "." } }))}</>)

    const items = screen.getAllByRole("listitem").map((item) => item.textContent)
    expect(items).toEqual(["app/", "config/", "README.md"])
  })

  it("renders an empty state for an empty directory", () => {
    render(<>{listFilesToolCard.renderExpanded(context({ parsedResult: { files: [] }, input: { path: "empty_dir" } }))}</>)
    expect(screen.getByText("empty_dir is empty.")).toBeInTheDocument()
  })

  it("falls back to null for a malformed payload", () => {
    expect(listFilesToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(listFilesToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
