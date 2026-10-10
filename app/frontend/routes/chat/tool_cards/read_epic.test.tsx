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
    const parsedResult = { epic: { id: 291, display_number: "the Tier 1 tool-card work", title: "Tier 1 Custom Tool Cards", state: "running" } }
    expect(readEpicToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("the Tier 1 tool-card work: Tier 1 Custom Tool Cards")
  })

  it("renders the canonical EPIC id, title, state, and repository", () => {
    const parsedResult = {
      epic: { id: 291, display_number: "the Tier 1 tool-card work", title: "Tier 1 Custom Tool Cards", state: "running", repository: "tkadauke/syrus" },
      child_jobs: []
    }

    render(<>{readEpicToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("the Tier 1 tool-card work")).toBeInTheDocument()
    expect(screen.getByText("Tier 1 Custom Tool Cards")).toBeInTheDocument()
    expect(screen.getByText("running")).toBeInTheDocument()
    expect(screen.getByText("tkadauke/syrus")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "the Tier 1 tool-card work" })).toHaveAttribute("href", "/epics/291")
    expect(screen.getByRole("button", { name: "Copy the Tier 1 tool-card work to clipboard" })).toBeInTheDocument()
  })

  it("renders dependency badges for depends-on and dependent Epics", () => {
    const parsedResult = {
      epic: {
        id: 291,
        display_number: "the Tier 1 tool-card work",
        title: "Tier 1 Custom Tool Cards",
        state: "running",
        depends_on_epics: [{ id: 288, display_number: "EPIC-58", title: "Extension point", state: "merged" }],
        dependent_epics: [{ id: 300, display_number: "EPIC-70", title: "Tier 2", state: "pending" }]
      },
      child_jobs: []
    }

    render(<>{readEpicToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("Depends on")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "EPIC-58" })).toHaveAttribute("href", "/epics/288")
    expect(screen.getByText(/merged/)).toBeInTheDocument()
    expect(screen.getByText("Dependents")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "EPIC-70" })).toHaveAttribute("href", "/epics/300")
    expect(screen.getByText(/pending/)).toBeInTheDocument()
  })

  it("renders the child Job chain with a done/total progress count", () => {
    const parsedResult = {
      epic: { id: 291, display_number: "the Tier 1 tool-card work", title: "Tier 1 Custom Tool Cards", state: "running" },
      child_jobs: [
        {
          id: 319,
          issue_title: "Add extension point",
          state: "merged",
          depends_on_jobs: [
            {
              id: 318,
              state: "closed",
              satisfaction_mode: "deployment_stage",
              required_deployment_stage_name: "production",
              latest_deployment_stage: { name: "staging", label: "Staging" }
            }
          ]
        },
        { id: 320, issue_title: "Add core tool cards", state: "running" }
      ]
    }

    render(<>{readEpicToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("Child Jobs (1/2)")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "JOB-319" })).toHaveAttribute("href", "/jobs/319")
    expect(screen.getByRole("link", { name: "JOB-320" })).toHaveAttribute("href", "/jobs/320")
    expect(screen.getByText("JOB-319 waits for JOB-318 · stage production · latest Staging")).toBeInTheDocument()
  })

  it("omits optional sections when fields are missing", () => {
    const parsedResult = { epic: { id: 291, state: "running" } }

    render(<>{readEpicToolCard.renderExpanded(context({ parsedResult }))}</>)

    // Falls back to the canonical EPIC slug for both the header pill and the title when
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
