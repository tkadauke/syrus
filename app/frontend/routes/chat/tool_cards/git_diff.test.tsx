import { fireEvent, render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import { normalizedToolCardParsedResult, normalizedToolName } from "../toolRendering"
import gitDiffToolCard from "./git_diff"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return { toolName: "git_diff", resultBody: "", resultError: false, parsedResult: null, ...overrides }
}

const SMALL_DIFF = [
  "diff --git a/app/models/job.rb b/app/models/job.rb",
  "index 1234567..89abcde 100644",
  "--- a/app/models/job.rb",
  "+++ b/app/models/job.rb",
  "@@ -1,2 +1,3 @@",
  " class Job",
  "+  # comment",
  " end"
].join("\n")

describe("git_diff tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(gitDiffToolCard.toolName).toBe("git_diff")
  })

  it("summarizes and renders no changes for a blank diff", () => {
    expect(gitDiffToolCard.collapsedSummary?.(context({ parsedResult: { diff: "" } }))).toBe("No uncommitted changes")

    render(<>{gitDiffToolCard.renderExpanded(context({ parsedResult: { diff: "" } }))}</>)
    expect(screen.getByText("No uncommitted changes.")).toBeInTheDocument()
  })

  it("summarizes a diff with added/deleted line counts", () => {
    const summary = gitDiffToolCard.collapsedSummary?.(context({ parsedResult: { diff: SMALL_DIFF } }))
    expect(summary).toMatch(/^\+1 -0 across 1 file$/)
  })

  it("shows changed file paths and keeps long lines inside a horizontal scroller", () => {
    const longDiff = SMALL_DIFF.replace("+  # comment", `+  # ${"x".repeat(500)}`)
    render(<>{gitDiffToolCard.renderExpanded(context({ parsedResult: { diff: longDiff } }))}</>)

    expect(screen.getByText("app/models/job.rb")).toBeInTheDocument()
    expect(screen.getByText("app/models/job.rb").closest("code")).toHaveClass("break-all")
    expect(screen.getByLabelText("Copy diff").closest("[data-code-surface-mode]")?.querySelector("pre")).toHaveClass("overflow-x-auto")
  })

  it("renders a large diff behind the shared bounded preview", () => {
    const manyFiles = Array.from({ length: 50 }, (_, i) =>
      [
        `diff --git a/file${i}.rb b/file${i}.rb`,
        "index 1234567..89abcde 100644",
        `--- a/file${i}.rb`,
        `+++ b/file${i}.rb`,
        "@@ -1,1 +1,2 @@",
        " line",
        "+added line"
      ].join("\n")
    ).join("\n")

    render(<>{gitDiffToolCard.renderExpanded(context({ parsedResult: { diff: manyFiles } }))}</>)
    expect(screen.getByText(/50 files/)).toBeInTheDocument()
    expect(screen.getByText("Showing first 300 of 350 lines.")).toBeInTheDocument()
    expect(screen.queryByText("diff --git a/file49.rb b/file49.rb")).not.toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Show full diff" }))
    expect(screen.getByRole("dialog", { name: "Full diff" })).toBeInTheDocument()
    expect(screen.getByText("diff --git a/file49.rb b/file49.rb")).toBeInTheDocument()
  })

  it("renders daemon failures with actionable markdown guidance", () => {
    const failure = "Local daemon not connected. Run `syrus local` in your repo to continue."
    expect(gitDiffToolCard.collapsedSummary?.(context({ resultBody: failure, resultError: true }))).toBe("Could not read the local diff")
    render(<>{gitDiffToolCard.renderExpanded(context({ resultBody: failure, resultError: true }))}</>)
    expect(screen.getByText("Could not read the local diff")).toBeInTheDocument()
    expect(screen.getByText("syrus local")).toBeInTheDocument()
  })

  it("accepts shared content and structured-content normalization envelopes", () => {
    const contentEnvelope = { content: [{ type: "text", text: JSON.stringify({ diff: SMALL_DIFF }) }] }
    const structuredEnvelope = { structured_content: { diff: SMALL_DIFF }, content: [] }
    expect(normalizedToolCardParsedResult(contentEnvelope)).toEqual({ diff: SMALL_DIFF })
    expect(normalizedToolCardParsedResult(structuredEnvelope)).toEqual({ diff: SMALL_DIFF })
    expect(gitDiffToolCard.collapsedSummary?.(context({ parsedResult: normalizedToolCardParsedResult(contentEnvelope) }))).toMatch(/across 1 file$/)
    expect(gitDiffToolCard.collapsedSummary?.(context({ parsedResult: normalizedToolCardParsedResult(structuredEnvelope) }))).toMatch(/across 1 file$/)
  })

  it("normalizes MCP-prefixed tool names", () => {
    expect(normalizedToolName("mcp__syrus-chat-sidecar__git_diff")).toBe("git_diff")
  })

  it("falls back to null for a malformed payload", () => {
    expect(gitDiffToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(gitDiffToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
