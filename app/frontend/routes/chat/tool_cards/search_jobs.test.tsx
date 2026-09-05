import { render, screen } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "../../../pluginToolCards"
import searchJobsToolCard from "./search_jobs"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "search_jobs",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

function renderCard(parsedResult: unknown) {
  return render(<MemoryRouter>{searchJobsToolCard.renderExpanded(context({ parsedResult }))}</MemoryRouter>)
}

describe("search_jobs tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(searchJobsToolCard.toolName).toBe("search_jobs")
  })

  it("renders the `results` array as a dense Job list", () => {
    const parsedResult = {
      total: 1,
      results: [
        { id: 4220, repository_slug: "tkadauke/syrus", issue_title: "Add core media, Job, and Epic tool cards", state: "open", pr_number: 9382, priority: "high" }
      ]
    }

    renderCard(parsedResult)

    expect(screen.getByRole("link", { name: "JOB-4220" })).toHaveAttribute("href", "/jobs/4220")
    expect(screen.getByText("Add core media, Job, and Epic tool cards")).toBeInTheDocument()
    expect(screen.getByText("#9382")).toBeInTheDocument()
    expect(screen.getByText("high")).toBeInTheDocument()
  })

  it("does not read the `jobs` key list_jobs uses", () => {
    expect(searchJobsToolCard.renderExpanded(context({ parsedResult: { jobs: [{ id: 1, state: "open" }] } }))).toBeNull()
  })

  it("falls back to null for an empty results list", () => {
    expect(searchJobsToolCard.renderExpanded(context({ parsedResult: { total: 0, results: [] } }))).toBeNull()
  })

  it("falls back to null for a malformed payload", () => {
    expect(searchJobsToolCard.renderExpanded(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(searchJobsToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
