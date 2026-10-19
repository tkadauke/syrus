import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import { toolCardContextForExample } from "@app/pluginToolCards"
import { normalizedToolCardParsedResult, normalizedToolName } from "../toolRendering"
import attachRepositoryToolCard, { examples } from "./attach_repository"

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

  it("renders and links every repository and workspace result field", () => {
    const parsedResult = {
      repository: { id: 1, slug: "tkadauke/syrus", default_branch: "main" },
      workspace_path: "/data/workspaces/chat-1",
      repository_path: "/data/workspaces/chat-1/syrus"
    }

    render(<>{attachRepositoryToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("tkadauke/syrus")).toBeInTheDocument()
    expect(screen.getByText("1").closest("a")).toHaveAttribute("href", "/repositories/1")
    expect(screen.getByText("tkadauke/syrus").closest("a")).toHaveAttribute("href", "/repositories/1")
    expect(screen.getByText("main")).toBeInTheDocument()
    expect(screen.getByText("/data/workspaces/chat-1")).toBeInTheDocument()
    expect(screen.getByText("/data/workspaces/chat-1/syrus")).toBeInTheDocument()
  })

  it("wraps long path and branch values without horizontal overflow", () => {
    const parsedResult = {
      repository: { id: 1, slug: "owner/repository", default_branch: "feature/a-very-long-branch-name" },
      workspace_path: "/data/with/a/very/long/workspace/path",
      repository_path: "/data/with/a/very/long/workspace/path/repository"
    }

    const { container } = render(<>{attachRepositoryToolCard.renderExpanded(context({ parsedResult }))}</>)
    expect(container.querySelectorAll("dd.break-all")).toHaveLength(4)
    expect(container.querySelector(".overflow-x-auto")).not.toBeInTheDocument()
  })

  it("shows pending and empty calls without inventing a result", () => {
    render(<>{attachRepositoryToolCard.renderExpanded(context({ input: { slug: "tkadauke/syrus" } }))}</>)
    expect(screen.getByText("Attaching tkadauke/syrus…")).toBeInTheDocument()

    render(<>{attachRepositoryToolCard.renderExpanded(context())}</>)
    expect(screen.getByText("Waiting for repository attachment…")).toBeInTheDocument()
  })

  it("renders a resultBody-only provider envelope after shared normalization", () => {
    const example = examples.find(({ id }) => id === "codex_result_body_envelope")!
    const rawContext = toolCardContextForExample("mcp__syrus-chat-sidecar__attach_repository", example)
    const toolContext = {
      ...rawContext,
      toolName: normalizedToolName(rawContext.toolName),
      parsedResult: normalizedToolCardParsedResult(rawContext.parsedResult)
    }

    expect(toolContext.toolName).toBe("attach_repository")
    expect(attachRepositoryToolCard.collapsedSummary?.(toolContext)).toBe("Attached tkadauke/syrus")
    render(<>{attachRepositoryToolCard.renderExpanded(toolContext)}</>)
    expect(screen.getByText("/data/chat_workspaces/123")).toBeInTheDocument()
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
