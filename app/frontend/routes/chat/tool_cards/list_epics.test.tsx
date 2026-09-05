import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
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
    const parsedResult = { epics: [{ id: 291, state: "running" }, { id: 292, state: "backlog" }] }
    expect(listEpicsToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("2 Epics")
  })

  it("renders a dense table with one row per Epic, including progress", () => {
    const parsedResult = {
      epics: [
        { id: 291, repository_slug: "tkadauke/syrus", title: "Tier 1 Custom Tool Cards", state: "running", child_job_count: 4, open_job_count: 1 }
      ]
    }

    render(<>{listEpicsToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByRole("table")).toBeInTheDocument()
    expect(screen.getByText("EPIC-291")).toBeInTheDocument()
    expect(screen.getByText("Tier 1 Custom Tool Cards")).toBeInTheDocument()
    expect(screen.getByText("3/4 done")).toBeInTheDocument()
  })

  it("renders a friendly empty state for a well-formed empty list", () => {
    render(<>{listEpicsToolCard.renderExpanded(context({ parsedResult: { epics: [] } }))}</>)
    expect(screen.getByText("No Epics found.")).toBeInTheDocument()
  })

  it("falls back to null for a malformed payload", () => {
    expect(listEpicsToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(listEpicsToolCard.renderExpanded(context({ parsedResult: { oops: true } }))).toBeNull()
  })

  it("falls back to null for a non-object payload", () => {
    expect(listEpicsToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
