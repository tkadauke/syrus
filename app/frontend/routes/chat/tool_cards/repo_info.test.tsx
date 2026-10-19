import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import repoInfoToolCard from "./repo_info"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return { toolName: "repo_info", resultBody: "", resultError: false, parsedResult: null, ...overrides }
}

describe("repo_info tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(repoInfoToolCard.toolName).toBe("repo_info")
  })

  it("summarizes the collapsed row with slug and default branch", () => {
    const parsedResult = { repository: { id: 1, slug: "tkadauke/syrus", default_branch: "main" } }
    expect(repoInfoToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("tkadauke/syrus (default: main)")
  })

  it("renders linked repository metadata, wrapping commit subjects, and linked/copyable refs", () => {
    const parsedResult = {
      repository: {
        id: 1,
        slug: "tkadauke/syrus",
        url: "https://github.com/tkadauke/syrus",
        default_branch: "main",
        trigger_label: "syrus",
        agent_provider: "claude",
        recent_commits: [{ sha: "abcdef1234567890", subject: "Add feature" }],
        branches: [{ name: "main", sha: "abcdef1234567890" }]
      }
    }

    render(<>{repoInfoToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("tkadauke/syrus")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "tkadauke/syrus" })).toHaveAttribute("href", "/repositories/1")
    expect(screen.getByRole("link", { name: "https://github.com/tkadauke/syrus" })).toHaveAttribute("href", "https://github.com/tkadauke/syrus")
    expect(screen.getByText("1")).toBeInTheDocument()
    expect(screen.getAllByRole("link", { name: "main" })).toHaveLength(2)
    expect(screen.getByText("label: syrus")).toBeInTheDocument()
    expect(screen.getByText("claude")).toBeInTheDocument()
    expect(screen.getByText("1 recent commit")).toBeInTheDocument()
    expect(screen.getByText("1 branch")).toBeInTheDocument()

    const commitLinks = screen.getAllByRole("link", { name: "abcdef123456" })
    expect(commitLinks).toHaveLength(2)
    expect(commitLinks[0]).toHaveAttribute("href", "https://github.com/tkadauke/syrus/commit/abcdef1234567890")
    expect(commitLinks[0].closest("li")).not.toHaveClass("truncate")
    expect(screen.getAllByRole("button", { name: "Copy abcdef1234567890 to clipboard" })).toHaveLength(2)
    expect(screen.getAllByRole("link", { name: "main" })[0]).toHaveAttribute("href", "https://github.com/tkadauke/syrus/tree/main")
  })

  it("shows explicit empty states when commits and branches are absent", () => {
    const parsedResult = { repository: { id: 1, slug: "tkadauke/syrus", default_branch: "main" } }
    render(<>{repoInfoToolCard.renderExpanded(context({ parsedResult }))}</>)
    expect(screen.getByText("No recent commits found.")).toBeInTheDocument()
    expect(screen.getByText("No branches found.")).toBeInTheDocument()
  })

  it("derives the attempted repository from an error result because the tool has no inputs", () => {
    const parsedResult = { repository: { slug: "acme/private" }, error: "GitHub access is unavailable" }
    const toolContext = context({ parsedResult, resultBody: JSON.stringify(parsedResult), resultError: true })

    expect(repoInfoToolCard.collapsedSummary?.(toolContext)).toBe("Repository info failed: GitHub access is unavailable")
    render(<>{repoInfoToolCard.renderExpanded(toolContext)}</>)

    expect(screen.getByText("Read repository info for acme/private")).toBeInTheDocument()
    expect(screen.getByText("GitHub access is unavailable")).toBeInTheDocument()
  })

  it("uses the shared name and result-envelope normalizers for provider-specific shapes", async () => {
    const { normalizedToolCardParsedResult, normalizedToolName } = await import("../toolRendering")
    const repository = { repository: { id: 7, slug: "acme/widgets", default_branch: "trunk", recent_commits: [], branches: [] } }
    const envelopes = [{ structured_content: repository }, { content: [{ type: "text", text: JSON.stringify(repository) }], structured_content: null }]

    for (const parsedResult of envelopes) {
      const normalizedContext = context({
        toolName: normalizedToolName("mcp__syrus-chat-sidecar__repo_info"),
        parsedResult: normalizedToolCardParsedResult(parsedResult)
      })
      expect(normalizedContext.toolName).toBe("repo_info")
      expect(repoInfoToolCard.collapsedSummary?.(normalizedContext)).toBe("acme/widgets (default: trunk)")
    }
  })

  it("falls back to null for a malformed payload", () => {
    expect(repoInfoToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(repoInfoToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
