import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
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
    expect(screen.getByText("draft")).toBeInTheDocument()
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
