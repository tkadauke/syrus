import { render, screen } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "../../../pluginToolCards"
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

function renderCard(parsedResult: unknown) {
  return render(<MemoryRouter>{readEpicToolCard.renderExpanded(context({ parsedResult }))}</MemoryRouter>)
}

describe("read_epic tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(readEpicToolCard.toolName).toBe("read_epic")
  })

  it("shows the canonical EPIC id, title, state, repository, dependency badges, and child Job chain/progress", () => {
    const parsedResult = {
      epic: {
        id: 291,
        display_number: "EPIC-291",
        title: "Tier 1 Custom Tool Cards",
        state: "open",
        repository: "tkadauke/syrus",
        depends_on_epics: [{ id: 288, title: "Extension point", state: "closed" }],
        dependent_epics: [{ id: 300, title: "Tier 2 cards", state: "backlog" }]
      },
      child_jobs: [
        { id: 4219, issue_title: "Add plugin-aware extension point", state: "merged" },
        { id: 4220, issue_title: "Add core media, Job, and Epic tool cards", state: "open" }
      ]
    }

    renderCard(parsedResult)

    expect(screen.getByRole("link", { name: "EPIC-291" })).toHaveAttribute("href", "/epics/291")
    expect(screen.getByText("Tier 1 Custom Tool Cards")).toBeInTheDocument()
    expect(screen.getByText("tkadauke/syrus")).toBeInTheDocument()

    expect(screen.getByText("Depends on")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "EPIC-288" })).toHaveAttribute("href", "/epics/288")
    expect(screen.getByText("Extension point")).toBeInTheDocument()

    expect(screen.getByText("Blocks")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "EPIC-300" })).toHaveAttribute("href", "/epics/300")
    expect(screen.getByText("Tier 2 cards")).toBeInTheDocument()

    expect(screen.getByText("1/2 landed")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "JOB-4219" })).toHaveAttribute("href", "/jobs/4219")
    expect(screen.getByRole("link", { name: "JOB-4220" })).toHaveAttribute("href", "/jobs/4220")
  })

  it("omits optional sections when the payload doesn't carry them", () => {
    renderCard({ epic: { id: 291, title: "Solo epic", state: "open" } })

    expect(screen.getByRole("link", { name: "EPIC-291" })).toBeInTheDocument()
    expect(screen.queryByText("Depends on")).not.toBeInTheDocument()
    expect(screen.queryByText("Blocks")).not.toBeInTheDocument()
    expect(screen.queryByText("Child Jobs")).not.toBeInTheDocument()
  })

  it("uses dark-mode-safe classes for the card container", () => {
    const { container } = renderCard({ epic: { id: 291, title: "Solo epic", state: "open" } })

    expect(container.firstElementChild).toHaveClass("dark:border-gray-700", "dark:bg-gray-900")
  })

  it("falls back to null for a malformed payload (missing epic or epic id)", () => {
    expect(readEpicToolCard.renderExpanded(context({ parsedResult: { epic: { title: "Nope" } } }))).toBeNull()
    expect(readEpicToolCard.renderExpanded(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(readEpicToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
