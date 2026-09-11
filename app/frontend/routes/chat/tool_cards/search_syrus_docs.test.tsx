import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import searchSyrusDocsToolCard from "./search_syrus_docs"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "search_syrus_docs",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

describe("search_syrus_docs tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(searchSyrusDocsToolCard.toolName).toBe("search_syrus_docs")
  })

  it("summarizes the collapsed row with the query and total hit count", () => {
    const parsedResult = { query: "landing queue", count: 4, results: [{ title: "Landing Queue" }, { title: "Auto Merge" }] }

    expect(searchSyrusDocsToolCard.collapsedSummary?.(context({ parsedResult }))).toBe('"landing queue" - 4 hits')
  })

  it("renders ranked results with title, path, source, reference, and snippets", () => {
    const parsedResult = {
      query: "prepare",
      count: 1,
      results: [{
        rank: 1,
        title: "Workflow Steps",
        heading: "Prepare",
        path: "config/syrus_docs/workflow_steps.md",
        source: "core",
        reference: "config/syrus_docs/workflow_steps.md > Prepare",
        snippet: "Runs setup commands before the agent starts."
      }]
    }

    render(<>{searchSyrusDocsToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("prepare")).toBeInTheDocument()
    expect(screen.getByText("1")).toBeInTheDocument()
    expect(screen.getByText("#1")).toBeInTheDocument()
    expect(screen.getByText("Workflow Steps > Prepare")).toBeInTheDocument()
    expect(screen.getByText("config/syrus_docs/workflow_steps.md")).toBeInTheDocument()
    expect(screen.getByText("core")).toBeInTheDocument()
    expect(screen.getByText("config/syrus_docs/workflow_steps.md > Prepare")).toBeInTheDocument()
    expect(screen.getByText("Runs setup commands before the agent starts.")).toBeInTheDocument()
  })

  it("renders a no-results state for an empty result list", () => {
    const parsedResult = { query: "xyzzy", count: 0, results: [], message: "No matching documentation found for 'xyzzy'. Try broader terms." }

    expect(searchSyrusDocsToolCard.collapsedSummary?.(context({ parsedResult }))).toBe('"xyzzy" - 0 hits')
    render(<>{searchSyrusDocsToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("No matching documentation found for 'xyzzy'. Try broader terms.")).toBeInTheDocument()
  })

  it("renders a tool error state", () => {
    render(<>{searchSyrusDocsToolCard.renderExpanded(context({ input: { query: "prepare" }, resultBody: "Error: query is required", resultError: true }))}</>)

    expect(searchSyrusDocsToolCard.collapsedSummary?.(context({ input: { query: "prepare" }, resultError: true }))).toBe('"prepare" failed')
    expect(screen.getByText("Error: query is required")).toBeInTheDocument()
  })

  it("renders a malformed payload state instead of throwing", () => {
    expect(searchSyrusDocsToolCard.collapsedSummary?.(context({ parsedResult: { oops: true }, input: { query: "prepare" } }))).toBe('"prepare" returned an unexpected response')

    render(<>{searchSyrusDocsToolCard.renderExpanded(context({ parsedResult: "not json" }))}</>)
    expect(screen.getByText("Unexpected Syrus Docs search response.")).toBeInTheDocument()
  })
})
