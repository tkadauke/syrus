import { fireEvent, render, screen, within } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import { normalizedToolCardParsedResult, normalizedToolName } from "../toolRendering"
import listEpicsToolCard from "./list_epics"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return { toolName: "list_epics", resultBody: "", resultError: false, parsedResult: null, ...overrides }
}

const epic = {
  id: 291,
  repository_slug: "tkadauke/syrus",
  title: "Tier 1 Custom Tool Cards With A Readable Wrapping Title",
  description: `**Markdown description** ${"with enough detail to require the full preview. ".repeat(8)}`,
  state: "in_progress",
  child_job_count: 4,
  open_job_count: 1,
  created_at: "2026-09-01T12:00:00Z"
}

describe("list_epics tool card", () => {
  it("registers under the normalized MCP tool name", () => {
    expect(listEpicsToolCard.toolName).toBe("list_epics")
    expect(normalizedToolName("mcp__syrus-chat-sidecar__list_epics")).toBe(listEpicsToolCard.toolName)
  })

  it("summarizes the collapsed row with an Epic count", () => {
    expect(
      listEpicsToolCard.collapsedSummary?.(
        context({
          parsedResult: {
            epics: [
              { id: 291, state: "running" },
              { id: 292, state: "backlog" }
            ]
          }
        })
      )
    ).toBe("2 Epics")
  })

  it.each([
    ["content text", { content: [{ type: "text", text: JSON.stringify({ epics: [epic] }) }], structured_content: null }],
    ["structured content", { content: [{ type: "text", text: "ignored" }], structured_content: { epics: [epic] } }]
  ])("renders shared-normalized %s MCP envelopes", (_label, envelope) => {
    render(
      <>{listEpicsToolCard.renderExpanded(context({ parsedResult: normalizedToolCardParsedResult(envelope), input: { state: "in_progress", limit: 1 } }))}</>
    )
    expect(screen.getByRole("table")).toBeInTheDocument()
    expect(screen.getAllByRole("link", { name: "EPIC-291" })[0]).toHaveAttribute("href", "/epics/291")
    expect(screen.getAllByRole("link", { name: "tkadauke/syrus" })[0]).toHaveAttribute("href", "https://github.com/tkadauke/syrus")
    expect(screen.getAllByText(epic.title)).toHaveLength(2)
    expect(screen.getAllByText("3/4 done")).toHaveLength(2)
    expect(screen.getByText("State: in_progress")).toBeInTheDocument()
    expect(screen.getByText("Limit: 1")).toBeInTheDocument()
    expect(screen.getByText(/Result limit reached/)).toBeInTheDocument()
    expect(screen.getByTitle(epic.created_at)).toHaveTextContent(/Sep 1, 2026/)
    expect(screen.getByTestId("epics-mobile-list")).toHaveClass("md:hidden")
  })

  it("renders Markdown descriptions with a Show more dialog and wrapping titles", () => {
    render(<>{listEpicsToolCard.renderExpanded(context({ parsedResult: { epics: [epic] } }))}</>)
    expect(screen.getAllByText(epic.title)[0]).toHaveClass("break-words")
    expect(screen.getAllByText("Markdown description")[0].tagName).toBe("STRONG")
    fireEvent.click(screen.getAllByRole("button", { name: "Show more" })[0])
    expect(screen.getByRole("dialog", { name: `${epic.title} description` })).toBeInTheDocument()
  })

  it("renders friendly empty and error states with query details", () => {
    const { rerender } = render(<>{listEpicsToolCard.renderExpanded(context({ input: { state: "ready", limit: 5 }, parsedResult: { epics: [] } }))}</>)
    expect(screen.getByText("No Epics found.")).toBeInTheDocument()
    expect(screen.getByText("State: ready")).toBeInTheDocument()
    expect(screen.getByText("Limit: 5")).toBeInTheDocument()
    rerender(<>{listEpicsToolCard.renderExpanded(context({ input: { state: "archived", limit: 8 }, resultError: true, resultBody: "permission denied" }))}</>)
    expect(screen.getByText("permission denied")).toBeInTheDocument()
    expect(screen.getByText("State: archived")).toBeInTheDocument()
    expect(screen.getByText("Limit: 8")).toBeInTheDocument()
    expect(screen.queryByText(/Result limit reached/)).not.toBeInTheDocument()
  })

  it.each([
    [0, 1, true],
    [-5, 1, true],
    [500, 100, false],
    [1.9, 1, true]
  ])("shows the backend-effective limit for requested limit %s", (requested, effective, limitReached) => {
    render(<>{listEpicsToolCard.renderExpanded(context({ input: { limit: requested }, parsedResult: { epics: [epic] } }))}</>)
    expect(screen.getByText(`Limit: ${effective}`)).toBeInTheDocument()
    const hint = screen.queryByText(/Result limit reached/)
    if (limitReached) expect(hint).toBeInTheDocument()
    else expect(hint).not.toBeInTheDocument()
  })

  it("falls back to null for malformed successful payloads", () => {
    expect(listEpicsToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(listEpicsToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })

  it("keeps desktop and mobile content grouped independently", () => {
    render(<>{listEpicsToolCard.renderExpanded(context({ parsedResult: { epics: [epic] } }))}</>)
    const mobile = screen.getByTestId("epics-mobile-list")
    expect(within(mobile).getByRole("link", { name: "EPIC-291" })).toBeInTheDocument()
    expect(within(mobile).getByText("Created")).toBeInTheDocument()
  })
})
