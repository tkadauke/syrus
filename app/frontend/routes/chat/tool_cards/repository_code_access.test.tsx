import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import listRepositoryFilesToolCard from "./list_repository_files"
import searchRepositoryCodeToolCard from "./search_repository_code"

function context(toolName: string, parsedResult: unknown): ToolCardContext {
  return { toolName, parsedResult, resultBody: JSON.stringify(parsedResult), resultError: false }
}

describe("repository code access tool cards", () => {
  it("makes an inconclusive empty search unmistakable", () => {
    const cardContext = context("search_repository_code", {
      status: "inconclusive",
      incomplete: true,
      reason: "time_budget",
      results: [],
      hint: "Search is incomplete; no match means no match in the searched portion only. Narrow path or retry.",
      coverage: { candidate_files: 500, searched_files: 80 }
    })

    expect(searchRepositoryCodeToolCard.collapsedSummary?.(cardContext)).toContain("Incomplete search")
    render(<>{searchRepositoryCodeToolCard.renderExpanded(cardContext)}</>)
    expect(screen.getByText("Search coverage is incomplete")).toBeInTheDocument()
    expect(screen.getByText(/searched portion only/i)).toBeInTheDocument()
    expect(screen.getByText("Searched 80 of 500 files")).toBeInTheDocument()
    expect(screen.getByText(/not a definitive no-match/i)).toBeInTheDocument()
  })

  it("shows incomplete file-list coverage", () => {
    const cardContext = context("list_repository_files", {
      status: "incomplete",
      incomplete: true,
      reason: "result_limit",
      entries: [{ path: "app/a.rb" }],
      hint: "Listing is incomplete. Narrow path or retry.",
      coverage: { candidate_entries: 12, returned_entries: 1 }
    })

    expect(listRepositoryFilesToolCard.collapsedSummary?.(cardContext)).toContain("Incomplete listing")
    render(<>{listRepositoryFilesToolCard.renderExpanded(cardContext)}</>)
    expect(screen.getByText("File listing is incomplete")).toBeInTheDocument()
    expect(screen.getByText("Returned 1 of 12 paths")).toBeInTheDocument()
  })
})
