import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import { toolResultPresentation } from "../toolRendering"
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

describe("list_jobs tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(listJobsToolCard.toolName).toBe("list_jobs")
  })

  it("is selected for an MCP-prefixed tool name", () => {
    const body = JSON.stringify({ jobs: [{ id: 1, state: "open" }] })
    expect(toolResultPresentation("mcp__syrus-chat-sidecar__list_jobs", body)).toMatchObject({ summary: "1 Job" })
  })

  it("summarizes the collapsed row with a Job count", () => {
    const parsedResult = {
      jobs: [
        { id: 1, state: "open" },
        { id: 2, state: "closed" }
      ]
    }
    expect(listJobsToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("2 Jobs")
  })

  it("renders a dense table with one row per Job", () => {
    const parsedResult = {
      jobs: [
        {
          id: 4048,
          repository_slug: "tkadauke/syrus",
          kind: "issue",
          issue_number: 91,
          pr_number: 12,
          branch_name: "syrus/cards/mobile-layout",
          state: "closed",
          closure_reason: "implemented",
          agent_provider: "codex",
          job_provider_setting: "default",
          priority: "high",
          issue_title: "Add **readable** tool cards",
          goal_provenance: { chat_goal_id: 77 },
          created_at: "2026-10-18T10:00:00Z",
          updated_at: "2026-10-19T11:30:00Z"
        },
        { id: 4049, repository_slug: "tkadauke/syrus", issue_title: "Fix bug", state: "queued", pr_number: null, priority: "medium" }
      ]
    }

    const { container } = render(
      <>{listJobsToolCard.renderExpanded(context({ input: { state: "open", label: "syrus:skip-prepare", limit: 10 }, parsedResult }))}</>
    )

    expect(screen.getByRole("table")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "JOB-4048" })).toHaveAttribute("href", "/jobs/4048")
    expect(screen.getByText("readable")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "PR #12" })).toHaveAttribute("href", "https://github.com/tkadauke/syrus/pull/12")
    expect(screen.getAllByRole("link", { name: "tkadauke/syrus" })[0]).toHaveAttribute("href", "https://github.com/tkadauke/syrus")
    expect(screen.getByRole("link", { name: "syrus/cards/mobile-layout" })).toHaveAttribute(
      "href",
      "https://github.com/tkadauke/syrus/tree/syrus%2Fcards%2Fmobile-layout"
    )
    expect(screen.getByText("Kind:").parentElement).toHaveTextContent("issue")
    expect(screen.getByText("Issue:").parentElement).toHaveTextContent("#91")
    expect(screen.getByText("implemented")).toBeInTheDocument()
    expect(screen.getByText("Agent:").parentElement).toHaveTextContent("codex")
    expect(screen.getByText("Setting:").parentElement).toHaveTextContent("default")
    expect(screen.getByText("Goal:").parentElement).toHaveTextContent("#77")
    expect(screen.getByText("Created:").parentElement).toHaveTextContent("2026-10-18T10:00:00Z")
    expect(screen.getByText("Updated:").parentElement).toHaveTextContent("2026-10-19T11:30:00Z")
    expect(screen.getByRole("link", { name: "JOB-4049" })).toHaveAttribute("href", "/jobs/4049")
    expect(screen.getByText("Fix bug")).toBeInTheDocument()
    expect(container.querySelector("table")).toHaveClass("block", "sm:table")
    expect(container.querySelector('td[data-label="Source"]')).toBeInTheDocument()
    expect(container.querySelector('td[data-label="Lifecycle"]')).toBeInTheDocument()
    expect(screen.getByText(/Showing 2, limit 10/)).toHaveTextContent("Label: syrus:skip-prepare")
  })

  it.each([
    [[{ id: 1, state: "open" }]],
    [{ structured_content: { jobs: [{ id: 1, state: "open" }] } }],
    [{ content: [{ type: "text", text: JSON.stringify({ jobs: [{ id: 1, state: "open" }] }) }] }]
  ])("accepts alternate result envelopes", (parsedResult) => {
    expect(listJobsToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("1 Job")
  })

  it("renders tool errors instead of treating them as malformed data", () => {
    render(<>{listJobsToolCard.renderExpanded(context({ resultBody: "Error: unavailable", resultError: true }))}</>)
    expect(screen.getByText("Error: unavailable")).toBeInTheDocument()
  })

  it("renders a friendly empty state for a well-formed empty list", () => {
    render(<>{listJobsToolCard.renderExpanded(context({ parsedResult: { jobs: [] } }))}</>)
    expect(screen.getByText("No Jobs found.")).toBeInTheDocument()
  })

  it("falls back to null for a malformed payload", () => {
    expect(listJobsToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(listJobsToolCard.renderExpanded(context({ parsedResult: { oops: true } }))).toBeNull()
  })

  it("falls back to null for a non-object payload", () => {
    expect(listJobsToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
