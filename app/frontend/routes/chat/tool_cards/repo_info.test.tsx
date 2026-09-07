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

  it("renders trigger label, agent provider, recent commits, and branches", () => {
    const parsedResult = {
      repository: {
        id: 1,
        slug: "tkadauke/syrus",
        default_branch: "main",
        trigger_label: "syrus",
        agent_provider: "claude",
        recent_commits: [{ sha: "abcdef1234567890", subject: "Add feature" }],
        branches: [{ name: "main", sha: "abcdef1234567890" }]
      }
    }

    render(<>{repoInfoToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("tkadauke/syrus")).toBeInTheDocument()
    expect(screen.getByText("label: syrus")).toBeInTheDocument()
    expect(screen.getByText("claude")).toBeInTheDocument()
    expect(screen.getByText("1 recent commit")).toBeInTheDocument()
    expect(screen.getByText("1 branch")).toBeInTheDocument()
  })

  it("omits commit/branch disclosures when absent", () => {
    const parsedResult = { repository: { id: 1, slug: "tkadauke/syrus", default_branch: "main" } }
    render(<>{repoInfoToolCard.renderExpanded(context({ parsedResult }))}</>)
    expect(screen.queryByText(/recent commit/)).not.toBeInTheDocument()
  })

  it("falls back to null for a malformed payload", () => {
    expect(repoInfoToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(repoInfoToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
