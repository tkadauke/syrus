import { fireEvent, render, screen } from "@testing-library/react"
import { beforeEach, describe, expect, it, vi } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import listRepositoriesToolCard from "./list_repositories"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return { toolName: "list_repositories", resultBody: "", resultError: false, parsedResult: null, ...overrides }
}

describe("list_repositories tool card", () => {
  beforeEach(() => {
    Object.assign(navigator, {
      clipboard: { writeText: vi.fn().mockResolvedValue(undefined) }
    })
  })

  it("registers under the exact MCP tool name", () => {
    expect(listRepositoriesToolCard.toolName).toBe("list_repositories")
  })

  it("summarizes the collapsed row using the pagination total", () => {
    const parsedResult = {
      repositories: [{ id: 1, slug: "tkadauke/syrus", owner: "tkadauke", name: "syrus" }],
      pagination: { page: 1, per_page: 20, total_count: 1, total_pages: 1, has_next_page: false }
    }
    expect(listRepositoriesToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("1 repository")
  })

  it("renders an empty state for an empty repository list", () => {
    const parsedResult = { repositories: [], pagination: { page: 1, per_page: 20, total_count: 0, total_pages: 0, has_next_page: false } }
    expect(listRepositoriesToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("No repositories")

    render(<>{listRepositoriesToolCard.renderExpanded(context({ parsedResult }))}</>)
    expect(screen.getByText("No repositories found.")).toBeInTheDocument()
  })

  it("renders a table row per repository and the pagination footer", () => {
    const parsedResult = {
      repositories: [
        { id: 1, slug: "tkadauke/syrus", owner: "tkadauke", name: "syrus", default_branch: "main", epic_dependency_policy: "linear" }
      ],
      pagination: { page: 2, per_page: 20, total_count: 21, total_pages: 2, has_next_page: false }
    }

    render(<>{listRepositoriesToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByRole("link", { name: "tkadauke/syrus" })).toHaveAttribute("href", "/repositories/1")
    fireEvent.click(screen.getByRole("button", { name: "Copy tkadauke/syrus to clipboard" }))
    expect(navigator.clipboard.writeText).toHaveBeenCalledWith("tkadauke/syrus")
    expect(screen.getByText("main")).toBeInTheDocument()
    expect(screen.getByText("linear")).toBeInTheDocument()
    expect(screen.getByText("Page 2 of 2")).toBeInTheDocument()
  })

  it("falls back to null for a malformed payload", () => {
    expect(listRepositoriesToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(listRepositoriesToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
