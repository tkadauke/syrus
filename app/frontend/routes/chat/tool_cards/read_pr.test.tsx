import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
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
        diff: { text: "diff --git a/x b/x\n+added", truncated: false, bytes: 25 }
      }
    }

    render(<>{readPrToolCard.renderExpanded(context({ parsedResult }))}</>)

    const link = screen.getByRole("link", { name: "#7" })
    expect(link).toHaveAttribute("href", "https://github.com/tkadauke/syrus/pull/7")
    expect(screen.getByText("Add tool cards")).toBeInTheDocument()
    expect(screen.getByText("Adds custom cards.")).toBeInTheDocument()
    expect(screen.getByText("open")).toBeInTheDocument()
    expect(screen.getByText("1 file")).toBeInTheDocument()
    expect(screen.getByText("+1")).toBeInTheDocument()
    expect(screen.queryByText(/Truncated/)).not.toBeInTheDocument()
  })

  it("renders a truncated-diff notice with omitted byte count", () => {
    const parsedResult = {
      pr: {
        number: 7,
        state: "open",
        diff: { text: "diff --git a/x b/x\n+added", truncated: true, bytes: 640020, omitted_bytes: 588820 }
      }
    }

    render(<>{readPrToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("Truncated — 588820 bytes omitted")).toBeInTheDocument()
  })

  it("falls back to plain text when html_url is absent", () => {
    const parsedResult = { pr: { number: 7, state: "open" } }
    render(<>{readPrToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.queryByRole("link")).not.toBeInTheDocument()
    expect(screen.getByText("#7")).toBeInTheDocument()
  })

  it("falls back to null for a malformed payload (missing pr object)", () => {
    expect(readPrToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(readPrToolCard.renderExpanded(context({ parsedResult: { oops: true } }))).toBeNull()
  })

  it("falls back to null for a non-object payload", () => {
    expect(readPrToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
