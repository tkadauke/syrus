import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import listJobWorkflowsToolCard from "./list_job_workflows"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "list_job_workflows",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

describe("list_job_workflows tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(listJobWorkflowsToolCard.toolName).toBe("list_job_workflows")
  })

  it("summarizes the collapsed row with a count", () => {
    const parsedResult = { workflows: [{ id: 1, state: "succeeded" }, { id: 2, state: "failed" }] }
    expect(listJobWorkflowsToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("2 Workflows")
  })

  it("renders a table row per workflow with trigger kind, state, summary, counts, and duration", () => {
    const parsedResult = {
      workflows: [
        {
          id: 42,
          trigger_kind: "pr_comment",
          state: "succeeded",
          summary: "Addressed review feedback",
          step_count: 5,
          run_count: 6,
          started_at: "2026-01-01T00:00:00Z",
          finished_at: "2026-01-01T00:02:14Z"
        }
      ]
    }

    render(<>{listJobWorkflowsToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("WF-42")).toBeInTheDocument()
    expect(screen.getByText("pr_comment")).toBeInTheDocument()
    expect(screen.getByText("succeeded")).toBeInTheDocument()
    expect(screen.getByText("Addressed review feedback")).toBeInTheDocument()
    expect(screen.getByText("5")).toBeInTheDocument()
    expect(screen.getByText("6")).toBeInTheDocument()
    expect(screen.getByText("2m 14s")).toBeInTheDocument()
  })

  it("renders an explicit empty state for a well-formed empty list", () => {
    render(<>{listJobWorkflowsToolCard.renderExpanded(context({ parsedResult: { workflows: [] } }))}</>)
    expect(screen.getByText("No Workflows found.")).toBeInTheDocument()
  })

  it("falls back to placeholders when optional fields are missing", () => {
    const parsedResult = { workflows: [{ id: 7, state: "queued" }] }
    render(<>{listJobWorkflowsToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("WF-7")).toBeInTheDocument()
    expect(screen.getAllByText("—").length).toBeGreaterThan(0)
  })

  it("falls back to null for a malformed payload", () => {
    expect(listJobWorkflowsToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(listJobWorkflowsToolCard.renderExpanded(context({ parsedResult: { oops: true } }))).toBeNull()
  })

  it("falls back to null for a non-object payload", () => {
    expect(listJobWorkflowsToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
