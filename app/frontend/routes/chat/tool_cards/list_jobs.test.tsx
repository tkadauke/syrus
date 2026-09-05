import { render, screen } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "../../../pluginToolCards"
import listJobsToolCard from "./list_jobs"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "list_jobs",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

function renderCard(parsedResult: unknown) {
  return render(<MemoryRouter>{listJobsToolCard.renderExpanded(context({ parsedResult }))}</MemoryRouter>)
}

describe("list_jobs tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(listJobsToolCard.toolName).toBe("list_jobs")
  })

  it("renders a dense list of Jobs with id, state, title, repository, PR, branch, and priority", () => {
    const parsedResult = {
      jobs: [
        { id: 4219, repository_slug: "tkadauke/syrus", issue_title: "Add plugin-aware extension point", state: "merged", pr_number: 9381, branch_name: "syrus/direct-4219", priority: "medium" },
        { id: 4220, repository_slug: "tkadauke/syrus", issue_title: "Add core media, Job, and Epic tool cards", state: "open", pr_number: null, branch_name: "syrus/direct-4220", priority: "high" }
      ]
    }

    renderCard(parsedResult)

    expect(screen.getByRole("link", { name: "JOB-4219" })).toHaveAttribute("href", "/jobs/4219")
    expect(screen.getByText("Add plugin-aware extension point")).toBeInTheDocument()
    expect(screen.getByText("#9381")).toBeInTheDocument()
    expect(screen.getAllByText("tkadauke/syrus")).toHaveLength(2)

    expect(screen.getByRole("link", { name: "JOB-4220" })).toHaveAttribute("href", "/jobs/4220")
    expect(screen.getByText("Add core media, Job, and Epic tool cards")).toBeInTheDocument()
    expect(screen.getByText("high")).toBeInTheDocument()
    expect(screen.queryByText("#null")).not.toBeInTheDocument()
  })

  it("falls back to null for an empty jobs list", () => {
    expect(listJobsToolCard.renderExpanded(context({ parsedResult: { jobs: [] } }))).toBeNull()
  })

  it("skips fields the payload doesn't carry instead of rendering placeholders", () => {
    const { container } = renderCard({ jobs: [{ id: 4048, state: "open" }] })

    expect(screen.getByRole("link", { name: "JOB-4048" })).toBeInTheDocument()
    expect(container.querySelectorAll("li")).toHaveLength(1)
    expect(screen.queryByText("#")).not.toBeInTheDocument()
  })

  it("uses dark-mode-safe classes for the list container", () => {
    const { container } = renderCard({ jobs: [{ id: 4048, state: "open" }] })

    expect(container.firstElementChild).toHaveClass("dark:border-gray-700", "dark:bg-gray-900")
  })

  it("falls back to null for a malformed payload", () => {
    expect(listJobsToolCard.renderExpanded(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(listJobsToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
