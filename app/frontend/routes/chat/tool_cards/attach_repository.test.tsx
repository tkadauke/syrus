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

  it("falls back to null for a malformed payload", () => {
    expect(attachRepositoryToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(attachRepositoryToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
