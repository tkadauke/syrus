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
    const parsedResult = {
      files: [
        { name: "app", is_dir: true },
        { name: "README.md", is_dir: false }
      ]
    }
    expect(listFilesToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("2 items")
  })

  it("renders directories before files with icons and optional sizes", () => {
    const parsedResult = {
      files: [
        { name: "README.md", is_dir: false, byte_size: 2048 },
        { name: "config", is_dir: true },
        { name: "app", is_dir: true }
      ]
    }

    render(<>{listFilesToolCard.renderExpanded(context({ parsedResult, input: { path: "." } }))}</>)

    const items = screen.getAllByRole("listitem").map((item) => item.textContent)
    expect(items).toEqual(["app/", "config/", "README.md2.0 KB"])
    expect(screen.getAllByRole("listitem")[0].querySelector("svg")).toBeInTheDocument()
  })

  it("shows copyable path and recursive/depth inputs without mobile truncation", () => {
    render(
      <>
        {listFilesToolCard.renderExpanded(
          context({
            parsedResult: { files: [{ name: "a-very-long-file-name-that-must-wrap.txt", is_dir: false }] },
            input: { path: "nested/very/long/path", recursive: true, max_depth: 3 }
          })
        )}
      </>
    )
    expect(screen.getByRole("button", { name: /Copy nested\/very\/long\/path to clipboard/i })).toBeInTheDocument()
    expect(screen.getByText("Yes")).toBeInTheDocument()
    expect(screen.getByText("3")).toBeInTheDocument()
    expect(screen.getByText(/a-very-long-file-name/)).toHaveClass("break-all")
  })

  it("renders an empty state for an empty directory", () => {
    render(<>{listFilesToolCard.renderExpanded(context({ parsedResult: { files: [] }, input: { path: "empty_dir" } }))}</>)
    expect(screen.getByText("empty_dir is empty.")).toBeInTheDocument()
  })

  it("renders plain, outcome, and MCP-envelope failures as styled cards", () => {
    const cases = [
      context({ input: { path: "missing" }, resultError: true, resultBody: "Local daemon not connected." }),
      context({ input: { path: "missing" }, resultError: true, parsedResult: { error: "directory does not exist" } }),
      context({ input: { path: "missing" }, parsedResult: { content: [{ type: "text", text: "Error: daemon unavailable" }], structured_content: null } })
    ]
    const { rerender } = render(<>{listFilesToolCard.renderExpanded(cases[0])}</>)
    expect(screen.getByText("List files failed")).toBeInTheDocument()
    rerender(<>{listFilesToolCard.renderExpanded(cases[1])}</>)
    expect(screen.getByText("directory does not exist")).toBeInTheDocument()
    rerender(<>{listFilesToolCard.renderExpanded(cases[2])}</>)
    expect(screen.getByText("daemon unavailable")).toBeInTheDocument()
  })

  it("renders pending results with input context", () => {
    const pending = context({ input: { path: "src" }, parsedResult: { state: "pending", message: "Waiting for daemon." } })
    expect(listFilesToolCard.collapsedSummary?.(pending)).toBe("File listing pending")
    render(<>{listFilesToolCard.renderExpanded(pending)}</>)
    expect(screen.getByText("pending")).toBeInTheDocument()
    expect(screen.getByText("Waiting for daemon.")).toBeInTheDocument()
  })

  it("falls back to null for a malformed payload", () => {
    expect(listFilesToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(listFilesToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
