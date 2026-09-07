import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
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

  it("renders a large diff behind the shared bounded preview", () => {
    const manyFiles = Array.from({ length: 50 }, (_, i) => [
      `diff --git a/file${i}.rb b/file${i}.rb`,
      "index 1234567..89abcde 100644",
      `--- a/file${i}.rb`,
      `+++ b/file${i}.rb`,
      "@@ -1,1 +1,2 @@",
      " line",
      "+added line"
    ].join("\n")).join("\n")

    render(<>{gitDiffToolCard.renderExpanded(context({ parsedResult: { diff: manyFiles } }))}</>)
    expect(screen.getByText(/50 files/)).toBeInTheDocument()
  })

  it("falls back to null for a malformed payload", () => {
    expect(gitDiffToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(gitDiffToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
