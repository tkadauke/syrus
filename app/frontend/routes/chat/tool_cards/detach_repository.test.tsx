import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import detachRepositoryToolCard from "./detach_repository"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return { toolName: "detach_repository", resultBody: "", resultError: false, parsedResult: null, ...overrides }
}

describe("detach_repository tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(detachRepositoryToolCard.toolName).toBe("detach_repository")
  })

  it("summarizes the collapsed row with the detached slug", () => {
    const parsedResult = { repository: { id: 1, slug: "tkadauke/syrus" }, remaining_repositories: [] }
    expect(detachRepositoryToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("Detached tkadauke/syrus")
  })

  it("renders slug, remaining repositories, and note", () => {
    const parsedResult = {
      repository: { id: 1, slug: "tkadauke/syrus" },
      remaining_repositories: [{ id: 2, slug: "tkadauke/other" }],
      note: "This was the chat's effective repository. tkadauke/other is now effective for file browsing and repo-scoped actions."
    }

    render(<>{detachRepositoryToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("tkadauke/syrus")).toBeInTheDocument()
    expect(screen.getByText("tkadauke/other")).toBeInTheDocument()
    expect(screen.getByText(/now effective for file browsing/)).toBeInTheDocument()
  })

  it("renders 'none' when no repositories remain attached", () => {
    const parsedResult = { repository: { id: 1, slug: "tkadauke/syrus" }, remaining_repositories: [] }

    render(<>{detachRepositoryToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("none")).toBeInTheDocument()
  })

  it("falls back to null for a malformed payload", () => {
    expect(detachRepositoryToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(detachRepositoryToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
