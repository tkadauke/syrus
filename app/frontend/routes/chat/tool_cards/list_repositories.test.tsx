import { fireEvent, render, screen } from "@testing-library/react"
import { beforeEach, describe, expect, it, vi } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import { normalizedToolCardParsedResult, normalizedToolName } from "../toolRendering"
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

  it("renders every repository field, input filters, and complete pagination", () => {
    const parsedResult = {
      repositories: [
        {
          id: 1,
          slug: "tkadauke/syrus",
          owner: "tkadauke",
          name: "syrus",
          default_branch: "main",
          epic_dependency_policy: "linear",
          created_at: "2026-01-08T12:30:00Z"
        }
      ],
      pagination: { page: 2, per_page: 20, total_count: 41, total_pages: 3, has_next_page: true }
    }

    render(<>{listRepositoriesToolCard.renderExpanded(context({ input: { page: 2, per_page: 20 }, parsedResult }))}</>)

    expect(screen.getAllByRole("link", { name: "tkadauke/syrus" })[0]).toHaveAttribute("href", "/repositories/1")
    fireEvent.click(screen.getAllByRole("button", { name: "Copy tkadauke/syrus to clipboard" })[0])
    expect(navigator.clipboard.writeText).toHaveBeenCalledWith("tkadauke/syrus")
    for (const value of ["tkadauke", "syrus", "main", "linear", "2026-01-08T12:30:00Z"]) {
      expect(screen.getAllByText(value).length).toBeGreaterThan(0)
    }
    expect(screen.getByText("Requested: page 2 · 20 per page")).toBeInTheDocument()
    expect(screen.getByText("Page 2 of 3 · 20 per page · 41 total · More pages available")).toBeInTheDocument()
  })

  it("keeps the internal repository link and adds the provider URL when supplied", () => {
    const parsedResult = {
      repositories: [{ id: 1, slug: "tkadauke/syrus", html_url: "https://github.com/tkadauke/syrus" }],
      pagination: { page: 1, per_page: 20, total_count: 1, total_pages: 1, has_next_page: false }
    }
    render(<>{listRepositoriesToolCard.renderExpanded(context({ parsedResult }))}</>)
    expect(screen.getAllByRole("link", { name: "tkadauke/syrus" })[0]).toHaveAttribute("href", "/repositories/1")
    expect(screen.getAllByRole("link", { name: "Open tkadauke/syrus on GitHub" })[0]).toHaveAttribute("href", "https://github.com/tkadauke/syrus")
    expect(screen.getAllByRole("link", { name: "Open tkadauke/syrus on GitHub" })[0]).toHaveAttribute("target", "_blank")
  })

  it("uses stacked mobile rows and a fixed wrapping desktop table without overflow containers", () => {
    const parsedResult = { repositories: [{ id: 1, slug: "acme/a-very-long-repository-name" }], pagination: {} }
    const { container } = render(<>{listRepositoriesToolCard.renderExpanded(context({ parsedResult }))}</>)
    expect(container.querySelector(".sm\\:hidden")).toBeInTheDocument()
    expect(container.querySelector("table")).toHaveClass("hidden", "table-fixed", "sm:table")
    expect(container.querySelector(".overflow-x-auto")).not.toBeInTheDocument()
  })

  it("renders result errors with the shared failure presentation", () => {
    const toolContext = context({ input: { page: 4 }, resultError: true, resultBody: "Repository service unavailable" })
    expect(listRepositoriesToolCard.collapsedSummary?.(toolContext)).toBe("Repository list failed: Repository service unavailable")
    render(<>{listRepositoriesToolCard.renderExpanded(toolContext)}</>)
    expect(screen.getByText("Repository list failed")).toBeInTheDocument()
    expect(screen.getByText("Repository service unavailable")).toBeInTheDocument()
    expect(screen.getByText("page 4")).toBeInTheDocument()
  })

  it("renders equivalent Claude and Codex MCP envelopes after shared normalization", () => {
    const payload = { repositories: [{ id: 7, slug: "acme/widgets" }], pagination: { total_count: 1 } }
    const codexEnvelope = { content: [{ type: "text", text: JSON.stringify(payload) }] }

    expect(normalizedToolName("mcp__syrus-chat-sidecar__list_repositories")).toBe("list_repositories")
    expect(normalizedToolName("syrus-chat-sidecar.list_repositories")).toBe("list_repositories")
    expect(listRepositoriesToolCard.collapsedSummary?.(context({ parsedResult: payload }))).toBe("1 repository")
    expect(listRepositoriesToolCard.collapsedSummary?.(context({ parsedResult: normalizedToolCardParsedResult(codexEnvelope) }))).toBe("1 repository")
  })

  it("falls back to null for a malformed payload", () => {
    expect(listRepositoriesToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(listRepositoriesToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
