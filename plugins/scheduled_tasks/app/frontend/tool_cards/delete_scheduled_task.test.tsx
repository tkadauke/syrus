import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import deleteScheduledTaskToolCard from "./delete_scheduled_task"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "delete_scheduled_task",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

const deleted = { scheduled_task_id: 12, label: "Nightly main-branch health check", deleted: true }

describe("delete_scheduled_task tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(deleteScheduledTaskToolCard.toolName).toBe("delete_scheduled_task")
  })

  it("summarizes the collapsed row with the deleted label and id", () => {
    expect(deleteScheduledTaskToolCard.collapsedSummary?.(context({ parsedResult: deleted }))).toBe(
      "Deleted 'Nightly main-branch health check' (#12)"
    )
  })

  it("renders the deleted outcome", () => {
    render(<>{deleteScheduledTaskToolCard.renderExpanded(context({ parsedResult: deleted }))}</>)

    expect(screen.getByText("deleted")).toBeInTheDocument()
    expect(screen.getByText("#12")).toBeInTheDocument()
    expect(screen.getByText("Nightly main-branch health check")).toBeInTheDocument()
    expect(screen.getByText("The task was removed and will never fire again.")).toBeInTheDocument()
  })

  it("falls back to null for a malformed payload", () => {
    const parsedResult = { oops: true }

    expect(deleteScheduledTaskToolCard.collapsedSummary?.(context({ parsedResult }))).toBeNull()
    expect(deleteScheduledTaskToolCard.renderExpanded(context({ parsedResult }))).toBeNull()
  })

  it("falls back to null for a non-object payload", () => {
    const parsedResult = "not json"

    expect(deleteScheduledTaskToolCard.collapsedSummary?.(context({ parsedResult }))).toBeNull()
    expect(deleteScheduledTaskToolCard.renderExpanded(context({ parsedResult }))).toBeNull()
  })
})
