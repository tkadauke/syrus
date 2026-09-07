import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
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

  it("categorizes modified, added, deleted, and untracked files", () => {
    const status = [
      " M app/models/job.rb",
      "A  app/models/new_file.rb",
      " D app/models/old_file.rb",
      "?? scratch.txt"
    ].join("\n")

    expect(gitStatusToolCard.collapsedSummary?.(context({ parsedResult: { status } }))).toBe("4 changed files")

    render(<>{gitStatusToolCard.renderExpanded(context({ parsedResult: { status } }))}</>)

    expect(screen.getByText("app/models/job.rb")).toBeInTheDocument()
    expect(screen.getByText("modified")).toBeInTheDocument()
    expect(screen.getByText("added")).toBeInTheDocument()
    expect(screen.getByText("deleted")).toBeInTheDocument()
    expect(screen.getByText("untracked")).toBeInTheDocument()
  })

  it("falls back to null for a malformed payload", () => {
    expect(gitStatusToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(gitStatusToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
