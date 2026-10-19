import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import { toolResultPresentation } from "../toolRendering"
import gitStatusToolCard from "./git_status"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return { toolName: "git_status", resultBody: "", resultError: false, parsedResult: null, ...overrides }
}

describe("git_status tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(gitStatusToolCard.toolName).toBe("git_status")
  })

  it("summarizes and renders a clean working tree", () => {
    expect(gitStatusToolCard.collapsedSummary?.(context({ parsedResult: { status: "" } }))).toBe("Working tree clean")

    render(<>{gitStatusToolCard.renderExpanded(context({ parsedResult: { status: "" } }))}</>)
    expect(screen.getByText("Working tree clean.")).toBeInTheDocument()
  })

  it("distinguishes staged, unstaged, and untracked files", () => {
    const status = [" M app/models/job.rb", "A  app/models/new_file.rb", " D app/models/old_file.rb", "?? scratch.txt"].join("\n")

    expect(gitStatusToolCard.collapsedSummary?.(context({ parsedResult: { status } }))).toBe("4 changed files")

    render(<>{gitStatusToolCard.renderExpanded(context({ parsedResult: { status } }))}</>)

    expect(screen.getByText("app/models/job.rb")).toBeInTheDocument()
    expect(screen.getByText("unstaged: modified")).toBeInTheDocument()
    expect(screen.getByText("staged: added")).toBeInTheDocument()
    expect(screen.getByText("unstaged: deleted")).toBeInTheDocument()
    expect(screen.getByText("untracked")).toBeInTheDocument()
  })

  it("renders rename source and destination plus conflict markers", () => {
    const status = "R  src/a/very/long/original-name.ts -> src/a/very/long/new-name.ts\nUU app/conflicted.tsx"
    render(<>{gitStatusToolCard.renderExpanded(context({ parsedResult: { status } }))}</>)

    expect(screen.getByText("staged: renamed")).toBeInTheDocument()
    expect(screen.getByText("src/a/very/long/original-name.ts")).toBeInTheDocument()
    expect(screen.getByLabelText("renamed to")).toBeInTheDocument()
    expect(screen.getByText("src/a/very/long/new-name.ts")).toBeInTheDocument()
    expect(screen.getByText("conflict UU")).toBeInTheDocument()
    expect(screen.getByText("app/conflicted.tsx").parentElement).toHaveClass("break-all")
  })

  it("shows explicit error and missing-result states", () => {
    const failed = context({ resultError: true, resultBody: "Local Mode daemon is not connected" })
    expect(gitStatusToolCard.collapsedSummary?.(failed)).toBe("Git status failed")
    render(<>{gitStatusToolCard.renderExpanded(failed)}</>)
    expect(screen.getByText("Git status unavailable: Local Mode daemon is not connected")).toBeInTheDocument()

    const empty = context()
    expect(gitStatusToolCard.collapsedSummary?.(empty)).toBe("No git status returned")
    render(<>{gitStatusToolCard.renderExpanded(empty)}</>)
    expect(screen.getByText("No git status was returned.")).toBeInTheDocument()
  })

  it("uses shared normalization for MCP prefixes and result envelopes", () => {
    const contentEnvelope = JSON.stringify({ content: [{ type: "text", text: JSON.stringify({ status: "?? from-content.txt" }) }] })
    expect(toolResultPresentation("mcp__syrus-chat-sidecar__git_status", contentEnvelope).summary).toBe("1 changed file")

    const structuredEnvelope = JSON.stringify({ structured_content: { status: "A  from-structured.txt" } })
    expect(toolResultPresentation("mcp__another-provider__git_status", structuredEnvelope).summary).toBe("1 changed file")
  })

  it("falls back to null for a malformed non-empty payload", () => {
    expect(gitStatusToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(gitStatusToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
