import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import i18n from "@app/i18n"
import { normalizedToolCardParsedResult, normalizedToolName } from "../toolRendering"
import listOpenPrsToolCard from "./list_open_prs"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "list_open_prs",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

describe("list_open_prs tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(listOpenPrsToolCard.toolName).toBe("list_open_prs")
  })

  it("summarizes the collapsed row with a count", () => {
    const parsedResult = { pull_requests: [{ number: 1 }, { number: 2 }] }
    expect(listOpenPrsToolCard.collapsedSummary?.(context({ parsedResult, input: { state: "closed", limit: 8 } }))).toBe("2 pull requests · closed · limit 8")
  })

  it("renders title, refs, draft, and mergeability per row", () => {
    const parsedResult = {
      pull_requests: [
        {
          number: 7,
          title: "Add tool cards",
          url: "https://github.com/acme/widgets/pull/7",
          head_ref: "syrus/direct-321",
          head_url: "https://github.com/acme/widgets/tree/syrus/direct-321",
          base_ref: "main",
          base_url: "https://github.com/acme/widgets/tree/main",
          mergeable: true,
          draft: false,
          created_at: "2026-05-03T09:00:00Z",
          updated_at: "2026-05-10T09:00:00Z"
        },
        { number: 8, title: "WIP", head_ref: "syrus/direct-400", base_ref: "main", mergeable: false, draft: true },
        { number: 9, title: "Pending check", head_ref: "syrus/direct-401", base_ref: "main", mergeable: null, draft: false }
      ]
    }

    render(<>{listOpenPrsToolCard.renderExpanded(context({ parsedResult, input: { state: "open", limit: 3 } }))}</>)

    expect(screen.getByRole("link", { name: "PR #7" })).toHaveAttribute("href", "https://github.com/acme/widgets/pull/7")
    expect(screen.getByText("Add tool cards")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "syrus/direct-321" })).toHaveAttribute("href", "https://github.com/acme/widgets/tree/syrus/direct-321")
    expect(screen.getByRole("link", { name: "main" })).toHaveAttribute("href", "https://github.com/acme/widgets/tree/main")
    expect(screen.getByText("mergeable")).toBeInTheDocument()
    expect(screen.getByText("conflicts")).toBeInTheDocument()
    expect(screen.getByText("checking")).toBeInTheDocument()
    expect(screen.getAllByText("Draft").length).toBeGreaterThan(0)
    expect(screen.getByText("May 3, 2026")).toHaveAttribute("datetime", "2026-05-03T09:00:00Z")
    expect(screen.getByText("Filter:").parentElement).toHaveTextContent("Filter:openLimit:3")
    expect(screen.getByRole("table")).toHaveClass("block", "sm:table")
    expect(screen.getByText("Add tool cards").closest("td")).toHaveAttribute("data-label", "Title")
  })

  it("uses the shared provider-envelope and tool-name normalizers", () => {
    const payload = { pull_requests: [{ number: 12 }] }
    expect(normalizedToolName("mcp__syrus-chat-sidecar__list_open_prs")).toBe("list_open_prs")
    expect(normalizedToolCardParsedResult({ content: [{ type: "text", text: JSON.stringify(payload) }] })).toEqual(payload)
    expect(normalizedToolCardParsedResult({ structured_content: payload })).toEqual(payload)
  })

  it("renders a dedicated error state", () => {
    render(<>{listOpenPrsToolCard.renderExpanded(context({ resultError: true, parsedResult: { error: "GitHub unavailable" } }))}</>)
    expect(screen.getByText("GitHub unavailable")).toBeInTheDocument()
  })

  it("localizes labels, states, and empty results", async () => {
    await i18n.changeLanguage("de")
    try {
      const cardContext = context({ input: { state: "merged", limit: 4 }, parsedResult: { pull_requests: [] } })
      expect(listOpenPrsToolCard.collapsedSummary?.(cardContext)).toBe("0 Pull Requests · zusammengeführt · Limit 4")
      render(<>{listOpenPrsToolCard.renderExpanded(cardContext)}</>)
      expect(screen.getByText("zusammengeführt")).toBeInTheDocument()
      expect(screen.getByText("Keine Pull Requests gefunden.")).toBeInTheDocument()
    } finally {
      await i18n.changeLanguage("en")
    }
  })

  it("renders an explicit empty state for a well-formed empty list", () => {
    render(<>{listOpenPrsToolCard.renderExpanded(context({ parsedResult: { pull_requests: [] } }))}</>)
    expect(screen.getByText("No pull requests found.")).toBeInTheDocument()
  })

  it("falls back to null for a malformed payload", () => {
    expect(listOpenPrsToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(listOpenPrsToolCard.renderExpanded(context({ parsedResult: { oops: true } }))).toBeNull()
  })

  it("falls back to null for a non-object payload", () => {
    expect(listOpenPrsToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
