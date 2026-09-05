import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import readEpicToolCard from "./read_epic"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "read_epic",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

describe("read_epic tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(readEpicToolCard.toolName).toBe("read_epic")
  })

  it("summarizes the collapsed row with the canonical EPIC id and title", () => {
    const parsedResult = { epic: { id: 291, display_number: "EPIC-291", title: "Tier 1 Custom Tool Cards", state: "running" } }
    expect(readEpicToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("EPIC-291: Tier 1 Custom Tool Cards")
  })

  it("renders the canonical EPIC id, title, state, and repository", () => {
    const parsedResult = {
      epic: { id: 291, display_number: "EPIC-291", title: "Tier 1 Custom Tool Cards", state: "running", repository: "tkadauke/syrus" },
      child_jobs: []
    }

    render(<>{readEpicToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("EPIC-291")).toBeInTheDocument()
    expect(screen.getByText("Tier 1 Custom Tool Cards")).toBeInTheDocument()
    expect(screen.getByText("running")).toBeInTheDocument()
    expect(screen.getByText("tkadauke/syrus")).toBeInTheDocument()
  })

  it("renders dependency badges for depends-on and dependent Epics", () => {
    const parsedResult = {
      epic: {
        id: 291,
        display_number: "EPIC-291",
        title: "Tier 1 Custom Tool Cards",
        state: "running",
        depends_on_epics: [{ id: 288, display_number: "EPIC-288", title: "Extension point", state: "merged" }],
        dependent_epics: [{ id: 300, display_number: "EPIC-300", title: "Tier 2", state: "pending" }]
      },
      child_jobs: []
    }

    render(<>{readEpicToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("Depends on")).toBeInTheDocument()
    expect(screen.getByText("EPIC-288 · merged")).toBeInTheDocument()
    expect(screen.getByText("Dependents")).toBeInTheDocument()
    expect(screen.getByText("EPIC-300 · pending")).toBeInTheDocument()
  })

  it("renders the child Job chain with a done/total progress count", () => {
    const parsedResult = {
      epic: { id: 291, display_number: "EPIC-291", title: "Tier 1 Custom Tool Cards", state: "running" },
      child_jobs: [
        { id: 4219, issue_title: "Add extension point", state: "merged" },
        { id: 4220, issue_title: "Add core tool cards", state: "running" }
      ]
    }

    render(<>{readEpicToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("Child Jobs (1/2)")).toBeInTheDocument()
    expect(screen.getByText("JOB-4219")).toBeInTheDocument()
    expect(screen.getByText("JOB-4220")).toBeInTheDocument()
  })

  it("omits optional sections when fields are missing", () => {
    const parsedResult = { epic: { id: 291, state: "running" } }

    render(<>{readEpicToolCard.renderExpanded(context({ parsedResult }))}</>)

    // Falls back to "EPIC-291" for both the header pill and the title when
    // display_number/title are absent, so it legitimately appears twice.
    expect(screen.getAllByText("EPIC-291")).toHaveLength(2)
    expect(screen.queryByText("Depends on")).not.toBeInTheDocument()
    expect(screen.queryByText(/Child Jobs/)).not.toBeInTheDocument()
  })

  it("falls back to null for a malformed payload (missing epic object)", () => {
    expect(readEpicToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(readEpicToolCard.renderExpanded(context({ parsedResult: { oops: true } }))).toBeNull()
  })

  it("falls back to null for a non-object payload", () => {
    expect(readEpicToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
