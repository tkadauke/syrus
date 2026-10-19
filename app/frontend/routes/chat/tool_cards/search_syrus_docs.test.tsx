import { fireEvent, render, screen, within } from "@testing-library/react"
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

  it("renders input, ranked results, scores, linked references, and expandable markdown", () => {
    const parsedResult = {
      query: "prepare",
      count: 1,
      results: [
        {
          rank: 1,
          title: "Workflow Steps",
          heading: "Prepare",
          path: "config/syrus_docs/workflow_steps.md",
          source: "core",
          reference: "config/syrus_docs/workflow_steps.md > Prepare",
          score: 2,
          text: `## Workflow setup\n\nRuns **setup commands** before the agent starts.\n\n${"Full details stay available. ".repeat(30)}`
        }
      ]
    }

    render(<>{searchSyrusDocsToolCard.renderExpanded(context({ input: { query: "prepare", limit: 3 }, parsedResult }))}</>)

    expect(screen.getByText("prepare")).toBeInTheDocument()
    expect(screen.getByText("1")).toBeInTheDocument()
    expect(screen.getByText("3")).toBeInTheDocument()
    expect(screen.getByText("#1")).toBeInTheDocument()
    expect(screen.getByText("Workflow Steps > Prepare")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "config/syrus_docs/workflow_steps.md" })).toHaveAttribute(
      "href",
      expect.stringContaining("github.com/tkadauke/syrus/blob/main/config/syrus_docs/workflow_steps.md")
    )
    expect(screen.getByText("core")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "config/syrus_docs/workflow_steps.md > Prepare" })).toHaveAttribute("href", expect.stringContaining("#prepare"))
    expect(screen.getByText("score 2")).toBeInTheDocument()
    expect(screen.getByText("setup commands").tagName).toBe("STRONG")
    fireEvent.click(screen.getByRole("button", { name: "Show more" }))
    expect(within(screen.getByRole("dialog")).getByRole("heading", { name: "Workflow setup" })).toBeInTheDocument()
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
    expect(searchSyrusDocsToolCard.collapsedSummary?.(context({ parsedResult: { oops: true }, input: { query: "prepare" } }))).toBe(
      '"prepare" returned an unexpected response'
    )

    render(<>{searchSyrusDocsToolCard.renderExpanded(context({ parsedResult: "not json" }))}</>)
    expect(screen.getByText("Unexpected Syrus Docs search response.")).toBeInTheDocument()
  })

  it("renders a pending state with the requested query and limit", () => {
    render(<>{searchSyrusDocsToolCard.renderExpanded(context({ input: { query: "graders", limit: 2 } }))}</>)

    expect(searchSyrusDocsToolCard.collapsedSummary?.(context({ input: { query: "graders" } }))).toBe('Searching Syrus Docs for "graders"')
    expect(screen.getByText("Searching Syrus Docs…")).toBeInTheDocument()
    expect(screen.getByText("2")).toBeInTheDocument()
  })
})
