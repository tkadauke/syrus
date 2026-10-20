import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import { pluginToolCardRendererFor } from "@app/pluginToolCards"
import { normalizedToolCardParsedResult, normalizedToolName } from "../toolRendering"
import listEpicsToolCard from "./list_epics"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "list_epics",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

describe("list_epics tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(listEpicsToolCard.toolName).toBe("list_epics")
  })

  it("summarizes the collapsed row with an Epic count", () => {
    const parsedResult = {
      epics: [
        { id: 291, state: "running" },
        { id: 292, state: "backlog" }
      ]
    }
    expect(listEpicsToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("2 Epics")
  })

  it("renders responsive Epic details, links, markdown, progress, and creation time", () => {
    const parsedResult = {
      epics: [
        {
          id: 291,
          repository_slug: "tkadauke/syrus",
          title: "Tier 1 Custom Tool Cards That Wrap Instead Of Truncating",
          description: "Supports **rich descriptions**.",
          state: "running",
          child_job_count: 4,
          open_job_count: 1,
          created_at: "2026-10-12T12:00:00Z"
        }
      ]
    }

    render(<>{listEpicsToolCard.renderExpanded(context({ parsedResult, input: { state: "running", limit: 10 } }))}</>)

    expect(screen.getByRole("table")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "EPIC-291" })).toHaveAttribute("href", "/epics/291")
    expect(screen.getByRole("button", { name: "Copy tkadauke/syrus to clipboard" })).toBeInTheDocument()
    expect(screen.getByText("Tier 1 Custom Tool Cards That Wrap Instead Of Truncating")).toHaveClass("break-words")
    expect(screen.getByText("rich descriptions", { exact: false })).toBeInTheDocument()
    expect(screen.getByText("3/4 done")).toBeInTheDocument()
    expect(screen.getAllByText("Created")).toHaveLength(2)
    expect(screen.getByText(/2026/)).toBeInTheDocument()
    expect(screen.getAllByText("running")).toHaveLength(2)
    expect(screen.getByText("10")).toBeInTheDocument()
  })

  it("offers the full markdown description when the preview is truncated", () => {
    const description = Array.from({ length: 8 }, (_, index) => `Line ${index + 1}`).join("\n")
    render(<>{listEpicsToolCard.renderExpanded(context({ parsedResult: { epics: [{ id: 1, state: "open", description }] } }))}</>)
    expect(screen.getByRole("button", { name: "Show more" })).toBeInTheDocument()
  })

  it.each([
    [500, 100, 100, true],
    [0, 1, 1, true],
    [-12, 1, 0, false]
  ])("uses effective backend limit %s as %s with %s rows", (requested, effective, count, reached) => {
    const epics = Array.from({ length: count }, (_, id) => ({ id: id + 1, state: "open" }))
    render(<>{listEpicsToolCard.renderExpanded(context({ input: { limit: requested }, parsedResult: { epics } }))}</>)
    expect(screen.getByText(String(effective))).toBeInTheDocument()
    expect(screen.queryByText("Limit reached; more Epics may be available.")).toBe(
      reached ? screen.getByText("Limit reached; more Epics may be available.") : null
    )
  })

  it("renders a friendly empty state for a well-formed empty list", () => {
    render(<>{listEpicsToolCard.renderExpanded(context({ input: { state: "approved", limit: 5 }, parsedResult: { epics: [] } }))}</>)
    expect(screen.getByText("No Epics found.")).toBeInTheDocument()
    expect(screen.getByText("approved")).toBeInTheDocument()
    expect(screen.getByText("5")).toBeInTheDocument()
  })

  it("keeps query details visible for errors", () => {
    render(
      <>
        {listEpicsToolCard.renderExpanded(
          context({ input: { state: "running", limit: 500 }, resultError: true, parsedResult: { error: "Database unavailable" } })
        )}
      </>
    )
    expect(screen.getByText("Database unavailable")).toBeInTheDocument()
    expect(screen.getByText("running")).toBeInTheDocument()
    expect(screen.getByText("100")).toBeInTheDocument()
  })

  it.each([
    { content: [{ type: "text", text: JSON.stringify({ epics: [{ id: 1, state: "open" }] }) }] },
    { structured_content: { epics: [{ id: 1, state: "open" }] } }
  ])("renders shared normalized MCP envelopes", (envelope) => {
    const parsedResult = normalizedToolCardParsedResult(envelope)
    render(<>{listEpicsToolCard.renderExpanded(context({ parsedResult }))}</>)
    expect(screen.getByRole("link", { name: "EPIC-1" })).toBeInTheDocument()
  })

  it("resolves an mcp-prefixed tool name to the agent-agnostic card", () => {
    expect(pluginToolCardRendererFor(normalizedToolName("mcp__syrus__list_epics"))).toBe(listEpicsToolCard)
  })

  it("falls back to null for a malformed payload", () => {
    expect(listEpicsToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(listEpicsToolCard.renderExpanded(context({ parsedResult: { oops: true } }))).toBeNull()
  })

  it("falls back to null for a non-object payload", () => {
    expect(listEpicsToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
