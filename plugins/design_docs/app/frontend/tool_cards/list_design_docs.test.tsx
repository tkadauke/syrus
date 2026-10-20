import { fireEvent, render, screen } from "@testing-library/react"
import { beforeEach, describe, expect, it, vi } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import { normalizedToolCardParsedResult, normalizedToolName } from "@app/routes/chat/toolRendering"
import listDesignDocsToolCard from "./list_design_docs"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "list_design_docs",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

describe("list_design_docs tool card", () => {
  beforeEach(() => {
    Object.assign(navigator, {
      clipboard: { writeText: vi.fn().mockResolvedValue(undefined) }
    })
  })

  it("registers under the exact MCP tool name", () => {
    expect(listDesignDocsToolCard.toolName).toBe("list_design_docs")
  })

  it("summarizes the collapsed row with a doc count", () => {
    const parsedResult = {
      design_docs: [
        { id: 1, doc_ref: "DOC-1", title: "A" },
        { id: 2, doc_ref: "DOC-2", title: "B" }
      ]
    }

    expect(listDesignDocsToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("2 design docs")
  })

  it("renders every returned field with linked doc and repository references", () => {
    const parsedResult = {
      design_docs: [
        {
          id: 20,
          doc_ref: "DOC-20",
          title: "Target Graphs for Project-Aware Workflows",
          state: "draft",
          visibility: "private",
          current_version_number: 7,
          updated_at: "2026-10-18T12:34:56Z",
          repository_ids: [41, "42"]
        }
      ]
    }

    render(<>{listDesignDocsToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByRole("link", { name: "DOC-20" })).toHaveAttribute("href", "/design_docs/20")
    fireEvent.click(screen.getByRole("button", { name: "Copy DOC-20 to clipboard" }))
    expect(navigator.clipboard.writeText).toHaveBeenCalledWith("DOC-20")
    expect(screen.getByText("Target Graphs for Project-Aware Workflows")).toBeInTheDocument()
    expect(screen.getByText("draft")).toBeInTheDocument()
    expect(screen.getByText("private")).toBeInTheDocument()
    expect(screen.getByText("v7")).toBeInTheDocument()
    expect(screen.getByText("Updated 2026-10-18T12:34:56Z")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Repository 41" })).toHaveAttribute("href", "/repositories/41")
    expect(screen.getByRole("link", { name: "Repository 42" })).toHaveAttribute("href", "/repositories/42")
  })

  it("shows the query, repository, and limit inputs", () => {
    render(
      <>
        {listDesignDocsToolCard.renderExpanded(
          context({
            input: { query: "queue", repository_id: 41, limit: 5 },
            parsedResult: { design_docs: [] }
          })
        )}
      </>
    )

    expect(screen.getByText("Query")).toBeInTheDocument()
    expect(screen.getByText("queue")).toBeInTheDocument()
    expect(screen.getByText("Limit")).toBeInTheDocument()
    expect(screen.getByText("5")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Repository 41" })).toHaveAttribute("href", "/repositories/41")
  })

  it("uses the shared tool-card shell and filterable primitive for plugin-owned rendering", () => {
    const parsedResult = {
      design_docs: [
        { id: 1, doc_ref: "DOC-20", title: "Target Graphs for Project-Aware Workflows", state: "draft" },
        { id: 2, doc_ref: "DOC-21", title: "K8s cluster viewer", state: "approved" }
      ]
    }

    const { container } = render(<>{listDesignDocsToolCard.renderExpanded(context({ parsedResult }))}</>)

    const card = container.querySelector(".before\\:bg-neutral-border")
    expect(card).toHaveClass("relative", "overflow-hidden", "bg-surface")
    expect(screen.getByRole("searchbox", { name: "Filter design docs" })).toBeInTheDocument()
    expect(screen.getByText("2 of 2")).toBeInTheDocument()
    expect(screen.getByText("DOC-21")).toBeInTheDocument()
  })

  it("falls back to null for a malformed payload (missing design_docs array)", () => {
    expect(listDesignDocsToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(listDesignDocsToolCard.renderExpanded(context({ parsedResult: { oops: true } }))).toBeNull()
  })

  it("falls back to null for a non-object payload", () => {
    expect(listDesignDocsToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })

  it("renders dedicated empty, pending, and error states", () => {
    const { rerender } = render(<>{listDesignDocsToolCard.renderExpanded(context({ parsedResult: { design_docs: [] } }))}</>)
    expect(screen.getByText("No design docs matched these filters.")).toBeInTheDocument()

    rerender(<>{listDesignDocsToolCard.renderExpanded(context())}</>)
    expect(screen.getByText("Waiting for the tool result.")).toBeInTheDocument()
    expect(listDesignDocsToolCard.collapsedSummary?.(context())).toBe("Listing design docs")

    rerender(<>{listDesignDocsToolCard.renderExpanded(context({ resultBody: "Error: repository not found", resultError: true }))}</>)
    expect(screen.getByRole("alert")).toHaveTextContent("Error: repository not found")
    expect(listDesignDocsToolCard.collapsedSummary?.(context({ resultError: true }))).toBe("Could not list design docs")
  })

  it("keeps rendering a structured design-doc list when the provider also marks the result as errored", () => {
    const parsedResult = { design_docs: [{ id: 21, doc_ref: "DOC-21", title: "K8s Cluster Viewer", state: "draft" }] }

    render(<>{listDesignDocsToolCard.renderExpanded(context({ parsedResult, resultError: true }))}</>)

    expect(screen.getByRole("link", { name: "DOC-21" })).toHaveAttribute("href", "/design_docs/21")
    expect(screen.getByText("K8s Cluster Viewer")).toBeInTheDocument()
    expect(screen.queryByRole("alert")).not.toBeInTheDocument()
    expect(listDesignDocsToolCard.collapsedSummary?.(context({ parsedResult, resultError: true }))).toBe("1 design doc")
  })

  it("renders provider-agnostically after tool-name and MCP-envelope normalization", () => {
    const payload = { design_docs: [{ id: 20, doc_ref: "DOC-20", title: "Wrapped doc", state: "draft" }] }
    const envelopes = [{ structured_content: payload }, { content: [{ type: "text", text: JSON.stringify(payload) }] }]

    for (const envelope of envelopes) {
      const toolName = normalizedToolName("mcp__design_docs__list_design_docs")
      expect(toolName).toBe("list_design_docs")
      const { unmount } = render(<>{listDesignDocsToolCard.renderExpanded(context({ toolName, parsedResult: normalizedToolCardParsedResult(envelope) }))}</>)
      expect(screen.getByText("Wrapped doc")).toBeInTheDocument()
      unmount()
    }
  })

  it("wraps long titles and stacks rows on mobile", () => {
    const { container } = render(
      <>
        {listDesignDocsToolCard.renderExpanded(
          context({
            parsedResult: {
              design_docs: [{ id: 20, doc_ref: "DOC-20", title: "A deliberately long design doc title", state: "draft" }]
            }
          })
        )}
      </>
    )

    expect(screen.getByText("A deliberately long design doc title")).toHaveClass("whitespace-normal", "break-words")
    expect(container.querySelector("li")).toHaveClass("flex-col", "sm:flex-row")
  })
})
