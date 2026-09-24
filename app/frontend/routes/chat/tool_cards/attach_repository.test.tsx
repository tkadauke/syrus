import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import attachRepositoryToolCard from "./attach_repository"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return { toolName: "attach_repository", resultBody: "", resultError: false, parsedResult: null, ...overrides }
}

describe("attach_repository tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(attachRepositoryToolCard.toolName).toBe("attach_repository")
  })

  it("summarizes the collapsed row with the attached slug", () => {
    const parsedResult = { repository: { id: 1, slug: "tkadauke/syrus", default_branch: "main" } }
    expect(attachRepositoryToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("Attached tkadauke/syrus")
  })

  it("renders slug, default branch, and repository path", () => {
    const parsedResult = {
      repository: { id: 1, slug: "tkadauke/syrus", default_branch: "main" },
      workspace_path: "/data/workspaces/chat-1",
      repository_path: "/data/workspaces/chat-1/syrus"
    }

    render(<>{attachRepositoryToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("tkadauke/syrus")).toBeInTheDocument()
    expect(screen.getByText("main")).toBeInTheDocument()
    expect(screen.getByText("/data/workspaces/chat-1/syrus")).toBeInTheDocument()
  })

  it("renders Codex MCP envelope errors as a failure card", () => {
    const parsedResult = {
      content: [
        {
          text: "Error: failed to attach tkadauke/syrus: git mirror: missing or invalid token",
          type: "text"
        }
      ],
      structured_content: null
    }

    const toolContext = context({
      input: { slug: "tkadauke/syrus" },
      parsedResult,
      resultBody: JSON.stringify(parsedResult, null, 2)
    })

    expect(attachRepositoryToolCard.collapsedSummary?.(toolContext)).toBe(
      "Repository attach failed: failed to attach tkadauke/syrus: git mirror: missing or invalid token"
    )

    render(<>{attachRepositoryToolCard.renderExpanded(toolContext)}</>)

    expect(screen.getByText("Repository attach failed")).toBeInTheDocument()
    expect(screen.getByText("failed to attach tkadauke/syrus: git mirror: missing or invalid token")).toBeInTheDocument()
    expect(screen.getByText("Attach tkadauke/syrus")).toBeInTheDocument()
  })

  it("falls back to null for a malformed payload", () => {
    expect(attachRepositoryToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(attachRepositoryToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
