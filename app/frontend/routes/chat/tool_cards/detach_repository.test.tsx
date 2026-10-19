import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import { normalizedToolCardParsedResult, normalizedToolName } from "../toolRendering"
import detachRepositoryToolCard from "./detach_repository"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return { toolName: "detach_repository", resultBody: "", resultError: false, parsedResult: null, ...overrides }
}

describe("detach_repository tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(detachRepositoryToolCard.toolName).toBe("detach_repository")
  })

  it("summarizes the collapsed row with the detached slug", () => {
    const parsedResult = { repository: { id: 1, slug: "tkadauke/syrus" }, detached: true, remaining_repositories: [] }
    expect(detachRepositoryToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("Detached tkadauke/syrus")
  })

  it("renders all result fields, repository links, and markdown prose", () => {
    const parsedResult = {
      repository: { id: 1, slug: "tkadauke/syrus" },
      detached: true,
      remaining_repositories: [{ id: 2, slug: "tkadauke/other" }],
      note: "This was the chat's **effective repository**. tkadauke/other is now effective for file browsing and repo-scoped actions."
    }

    render(<>{detachRepositoryToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByRole("link", { name: "tkadauke/syrus" })).toHaveAttribute("href", "/repositories/1")
    expect(screen.getByRole("link", { name: "tkadauke/other" })).toHaveAttribute("href", "/repositories/2")
    expect(screen.getByText("1")).toBeInTheDocument()
    expect(screen.getByText("detached")).toBeInTheDocument()
    expect(screen.getByText("effective repository", { selector: "strong" })).toBeInTheDocument()
    expect(screen.getByText(/now effective for file browsing/)).toBeInTheDocument()
  })

  it("renders an empty state when no repositories remain attached", () => {
    const parsedResult = { repository: { id: 1, slug: "tkadauke/syrus" }, detached: true, remaining_repositories: [] }

    render(<>{detachRepositoryToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("No repositories remain attached.")).toBeInTheDocument()
  })

  it("renders pending state and keeps a short non-prose note inline", () => {
    const parsedResult = { repository: { id: 1, slug: "tkadauke/syrus" }, detached: false, remaining_repositories: [], note: "Awaiting confirmation" }

    render(<>{detachRepositoryToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("pending")).toBeInTheDocument()
    expect(screen.getByText("Awaiting confirmation")).toBeInTheDocument()
  })

  it("normalizes provider-prefixed names and Codex MCP result envelopes", () => {
    const envelope = {
      content: [{ type: "text", text: JSON.stringify({ repository: { id: 9, slug: "tkadauke/syrus" }, detached: true, remaining_repositories: [] }) }],
      structuredContent: null
    }
    const toolContext = context({
      toolName: normalizedToolName("mcp__syrus-chat-sidecar__detach_repository"),
      parsedResult: normalizedToolCardParsedResult(envelope)
    })

    expect(toolContext.toolName).toBe("detach_repository")
    expect(detachRepositoryToolCard.collapsedSummary?.(toolContext)).toBe("Detached tkadauke/syrus")
  })

  it("renders Codex MCP envelope errors as a failure card", () => {
    const parsedResult = {
      content: [{ type: "text", text: "Error: repository tkadauke/syrus is not attached to this chat" }],
      structured_content: null
    }
    const toolContext = context({ input: { slug: "tkadauke/syrus" }, parsedResult, resultBody: JSON.stringify(parsedResult) })

    expect(detachRepositoryToolCard.collapsedSummary?.(toolContext)).toBe("Repository detach failed: repository tkadauke/syrus is not attached to this chat")
    render(<>{detachRepositoryToolCard.renderExpanded(toolContext)}</>)
    expect(screen.getByText("Repository detach failed")).toBeInTheDocument()
    expect(screen.getByText("Detach tkadauke/syrus")).toBeInTheDocument()
  })

  it("falls back to null for a malformed payload", () => {
    expect(detachRepositoryToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(detachRepositoryToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
