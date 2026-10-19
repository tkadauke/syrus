import { fireEvent, render, screen } from "@testing-library/react"
import { beforeEach, describe, expect, it, vi } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import { normalizedToolCardParsedResult, toolResultPresentation } from "../toolRendering"
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

  it("renders the title, a GitHub link, state, body, and diff stats", () => {
    const parsedResult = {
      pr: {
        number: 7,
        title: "Add tool cards",
        body: "Adds custom cards.",
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
    expect(screen.getByText("Adds custom cards.")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "tkadauke/syrus" })).toHaveAttribute("href", "https://github.com/tkadauke/syrus")
    expect(screen.getByRole("link", { name: "x" })).toHaveAttribute("href", "https://github.com/tkadauke/syrus/pull/7/files")
    expect(screen.getByText("open")).toBeInTheDocument()
    expect(screen.getByText("1 file")).toBeInTheDocument()
    expect(screen.getByText("+1")).toBeInTheDocument()
    expect(screen.getByText("25 bytes returned")).toBeInTheDocument()
    expect(screen.queryByText(/Truncated/)).not.toBeInTheDocument()
  })

  it("renders a truncated-diff notice with omitted byte count", () => {
    const parsedResult = {
      pr: {
        number: 7,
        state: "open",
        diff: { text: "diff --git a/x b/x\n@@ -0,0 +1 @@\n+added", truncated: true, bytes: 640020, omitted_bytes: 588820 }
      }
    }

    render(<>{readPrToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("Truncated — 588820 bytes omitted")).toBeInTheDocument()
  })

  it("falls back to plain text when html_url is absent", () => {
    const parsedResult = { pr: { number: 7, state: "open" } }
    render(<>{readPrToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.queryByRole("link")).not.toBeInTheDocument()
    expect(screen.getAllByText("PR #7").length).toBeGreaterThan(0)
    expect(screen.getByRole("button", { name: "Copy PR #7 to clipboard" })).toBeInTheDocument()
    expect(screen.getByText("Unknown repository")).toBeInTheDocument()
    expect(screen.getByText("No PR description.")).toBeInTheDocument()
    expect(screen.getByText("No diff returned.")).toBeInTheDocument()
  })

  it("shows explicit empty body and diff states", () => {
    const parsedResult = { pr: { number: 7, body: "", state: "open", diff: { text: "", truncated: false, bytes: 0, omitted_bytes: 0 } } }
    render(<>{readPrToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("No PR description.")).toBeInTheDocument()
    expect(screen.getByText("No changes in diff.")).toBeInTheDocument()
    expect(screen.getByText("0 bytes returned")).toBeInTheDocument()
  })

  it("falls back to null for a malformed payload (missing pr object)", () => {
    expect(readPrToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(readPrToolCard.renderExpanded(context({ parsedResult: { oops: true } }))).toBeNull()
  })

  it("falls back to null for a non-object payload", () => {
    expect(readPrToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })

  it("accepts a JSON string parsedResult", () => {
    const parsedResult = JSON.stringify({ pr: { number: 8, title: "String payload", state: "open" } })

    render(<>{readPrToolCard.renderExpanded(context({ parsedResult }))}</>)
    expect(screen.getByText("String payload")).toBeInTheDocument()
  })

  it("uses shared normalization for content text and structured content envelopes", () => {
    const textPayload = { pr: { number: 9, state: "open" } }
    const structuredPayload = { pr: { number: 10, state: "closed" } }

    expect(normalizedToolCardParsedResult({ content: [{ type: "text", text: JSON.stringify(textPayload) }] })).toEqual(textPayload)
    expect(normalizedToolCardParsedResult({ content: [{ type: "text", text: "ignored" }], structured_content: structuredPayload })).toEqual(structuredPayload)
  })

  it("normalizes an mcp-prefixed tool name and summarizes plain-text failures", () => {
    const payload = JSON.stringify({ pr: { number: 11, state: "open" } })
    expect(toolResultPresentation("mcp__syrus__read_pr", payload).summary).toBe("PR #11 (open)")

    const failure = toolResultPresentation("mcp__syrus__read_pr", "Error: GitHub unavailable", true, "Error: GitHub unavailable", { pr_number: 11 })
    expect(failure).toMatchObject({ kind: "error", summary: expect.stringContaining("PR read failed") })
  })
})
