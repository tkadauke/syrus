import { fireEvent, render, screen } from "@testing-library/react"
import { beforeEach, describe, expect, it, vi } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import readPrToolCard from "./read_pr"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "read_pr",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

describe("read_pr tool card", () => {
  beforeEach(() => {
    Object.assign(navigator, {
      clipboard: { writeText: vi.fn().mockResolvedValue(undefined) }
    })
  })

  it("registers under the exact MCP tool name", () => {
    expect(readPrToolCard.toolName).toBe("read_pr")
  })

  it("summarizes the collapsed row with the PR number and state", () => {
    const parsedResult = { pr: { number: 7, state: "open" } }
    expect(readPrToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("PR #7 (open)")
  })

  it("renders linked PR and repository refs, markdown body, changed files, and diff stats", () => {
    const parsedResult = {
      pr: {
        number: 7,
        title: "Add tool cards",
        body: "Adds **custom** cards.",
        state: "open",
        html_url: "https://github.com/tkadauke/syrus/pull/7",
        diff: { text: "diff --git a/x b/x\n@@ -0,0 +1 @@\n+added", truncated: false, bytes: 25 }
      }
    }

    render(<>{readPrToolCard.renderExpanded(context({ parsedResult }))}</>)

    const link = screen.getByRole("link", { name: "PR #7" })
    expect(link).toHaveAttribute("href", "https://github.com/tkadauke/syrus/pull/7")
    fireEvent.click(screen.getByRole("button", { name: "Copy PR #7 to clipboard" }))
    expect(navigator.clipboard.writeText).toHaveBeenCalledWith("PR #7")
    expect(screen.getByText("Add tool cards")).toBeInTheDocument()
    expect(screen.getByText("custom").tagName).toBe("STRONG")
    expect(screen.getByRole("link", { name: "tkadauke/syrus" })).toHaveAttribute("href", "https://github.com/tkadauke/syrus")
    expect(screen.getByRole("link", { name: "x" })).toHaveAttribute("href", "https://github.com/tkadauke/syrus/pull/7/files")
    expect(screen.getByText("open")).toBeInTheDocument()
    expect(screen.getByText("1 file")).toBeInTheDocument()
    expect(screen.getByText("+1")).toBeInTheDocument()
    expect(screen.getByText("25 bytes total")).toBeInTheDocument()
    expect(screen.queryByText(/truncated/i)).not.toBeInTheDocument()
  })

  it("renders a truncated-diff notice with total and omitted byte counts", () => {
    const parsedResult = {
      pr: {
        number: 7,
        state: "open",
        diff: { text: "diff --git a/x b/x\n@@ -0,0 +1 @@\n+added", truncated: true, bytes: 640020, omitted_bytes: 588820 }
      }
    }

    render(<>{readPrToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("640,020 bytes total")).toBeInTheDocument()
    expect(screen.getByText("Diff truncated — 588,820 bytes omitted")).toBeInTheDocument()
  })

  it("shows explicit empty body and empty diff states", () => {
    const parsedResult = { pr: { number: 7, title: "Empty", body: "", state: "open", diff: { text: "", truncated: false, bytes: 0 } } }
    render(<>{readPrToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("No PR description provided.")).toBeInTheDocument()
    expect(screen.getByText("No diff content returned.")).toBeInTheDocument()
    expect(screen.getByText("0 bytes total")).toBeInTheDocument()
  })

  it("shows an unavailable diff state", () => {
    render(<>{readPrToolCard.renderExpanded(context({ parsedResult: { pr: { number: 7, state: "open" } } }))}</>)
    expect(screen.getByText("No diff is available for this PR.")).toBeInTheDocument()
  })

  it("offers the full markdown body in a Show more modal", () => {
    const body = Array.from({ length: 8 }, (_, index) => `Line ${index + 1}`).join("\n")
    render(<>{readPrToolCard.renderExpanded(context({ parsedResult: { pr: { number: 7, state: "open", body } } }))}</>)

    fireEvent.click(screen.getByRole("button", { name: "Show more" }))
    expect(screen.getByRole("dialog", { name: "Full PR body" })).toHaveTextContent("Line 8")
  })

  it.each([
    ["text content", { content: [{ type: "text", text: JSON.stringify({ pr: { number: 8, state: "open" } }) }], structured_content: null }],
    ["structured content", { content: [], structured_content: { pr: { number: 9, state: "closed" } } }],
    ["string parsedResult", JSON.stringify({ pr: { number: 10, state: "open" } })]
  ])("normalizes %s results", (_label, parsedResult) => {
    render(<>{readPrToolCard.renderExpanded(context({ toolName: "mcp__syrus-chat-sidecar__read_pr", parsedResult }))}</>)
    expect(screen.getAllByText(/PR #(8|9|10)/).length).toBeGreaterThan(0)
  })

  it("renders a failure result with the attempted PR", () => {
    const parsedResult = { content: [{ type: "text", text: "Error: pull request not found: 404" }], structured_content: null }
    render(<>{readPrToolCard.renderExpanded(context({ input: { pr_number: 404 }, parsedResult, resultError: true }))}</>)

    expect(screen.getByText("pull request not found: 404")).toBeInTheDocument()
    expect(screen.getByText("Read PR #404")).toBeInTheDocument()
  })

  it("falls back to plain text when html_url is absent", () => {
    const parsedResult = { pr: { number: 7, state: "open" } }
    render(<>{readPrToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.queryByRole("link")).not.toBeInTheDocument()
    expect(screen.getAllByText("PR #7").length).toBeGreaterThan(0)
    expect(screen.getByRole("button", { name: "Copy PR #7 to clipboard" })).toBeInTheDocument()
  })

  it("falls back to null for a malformed payload (missing pr object)", () => {
    expect(readPrToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(readPrToolCard.renderExpanded(context({ parsedResult: { oops: true } }))).toBeNull()
  })

  it("falls back to null for a non-object payload", () => {
    expect(readPrToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
