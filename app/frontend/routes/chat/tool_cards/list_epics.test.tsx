import { render, screen } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "../../../pluginToolCards"
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

function renderCard(parsedResult: unknown) {
  return render(<MemoryRouter>{listEpicsToolCard.renderExpanded(context({ parsedResult }))}</MemoryRouter>)
}

describe("list_epics tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(listEpicsToolCard.toolName).toBe("list_epics")
  })

  it("renders a dense list of Epics with id, state, title, repository, and open/total child Job count", () => {
    const parsedResult = {
      epics: [
        { id: 291, repository_slug: "tkadauke/syrus", title: "Tier 1 Custom Tool Cards", state: "open", child_job_count: 5, open_job_count: 2 }
      ]
    }

    renderCard(parsedResult)

    expect(screen.getByRole("link", { name: "EPIC-291" })).toHaveAttribute("href", "/epics/291")
    expect(screen.getByText("Tier 1 Custom Tool Cards")).toBeInTheDocument()
    expect(screen.getByText("tkadauke/syrus")).toBeInTheDocument()
    expect(screen.getByText("2/5 open")).toBeInTheDocument()
  })

  it("falls back to null for an empty epics list", () => {
    expect(listEpicsToolCard.renderExpanded(context({ parsedResult: { epics: [] } }))).toBeNull()
  })

  it("skips the progress readout when child_job_count isn't present", () => {
    renderCard({ epics: [{ id: 291, title: "Solo epic", state: "open" }] })

    expect(screen.getByRole("link", { name: "EPIC-291" })).toBeInTheDocument()
    expect(screen.queryByText(/\d+\/\d+ open/)).not.toBeInTheDocument()
  })

  it("uses dark-mode-safe classes for the list container", () => {
    const { container } = renderCard({ epics: [{ id: 291, title: "Solo epic", state: "open" }] })

    expect(container.firstElementChild).toHaveClass("dark:border-gray-700", "dark:bg-gray-900")
  })

  it("falls back to null for a malformed payload", () => {
    expect(listEpicsToolCard.renderExpanded(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(listEpicsToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
