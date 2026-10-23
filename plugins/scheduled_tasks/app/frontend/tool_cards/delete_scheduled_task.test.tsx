import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import deleteScheduledTaskToolCard, { examples } from "./delete_scheduled_task"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "delete_scheduled_task",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

const deleted = {
  scheduled_task_id: 12,
  label: "Nightly main-branch health check",
  repository_id: 7,
  repository_slug: "acme/widgets",
  schedule_explanation: "Every day at 02:00 UTC",
  schedule_timezone: "UTC",
  deleted: true
}

describe("delete_scheduled_task tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(deleteScheduledTaskToolCard.toolName).toBe("delete_scheduled_task")
  })

  it("summarizes the collapsed row with the deleted label and id", () => {
    expect(deleteScheduledTaskToolCard.collapsedSummary?.(context({ parsedResult: deleted }))).toBe("Deleted 'Nightly main-branch health check' (#12)")
  })

  it("renders all deleted-task context without linking the removed task", () => {
    render(<>{deleteScheduledTaskToolCard.renderExpanded(context({ parsedResult: deleted }))}</>)

    expect(screen.getByText("deleted")).toBeInTheDocument()
    expect(screen.getByText("TASK-12")).toBeInTheDocument()
    expect(screen.queryByRole("link", { name: "TASK-12" })).not.toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Copy TASK-12 to clipboard" })).toBeInTheDocument()
    expect(screen.getByText("Nightly main-branch health check")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "acme/widgets" })).toHaveAttribute("href", "/repositories/7")
    expect(screen.getByText("Every day at 02:00 UTC (UTC)")).toBeInTheDocument()
    expect(screen.getByText("The task was removed and will never fire again.")).toBeInTheDocument()
  })

  it("accepts a nested scheduled-task result envelope", () => {
    render(
      <>{deleteScheduledTaskToolCard.renderExpanded(context({ parsedResult: { scheduled_task: { ...deleted, id: 12, scheduled_task_id: undefined } } }))}</>
    )

    expect(screen.getByText("TASK-12")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "acme/widgets" })).toBeInTheDocument()
  })

  it("renders not-found and write-access failures as styled error cards", () => {
    const errors = [
      { resultBody: "scheduled task not found: 404", parsedResult: null },
      { resultBody: "", parsedResult: { error: { message: "repository write access is required to change this scheduled task" } } }
    ]

    for (const error of errors) {
      const { unmount } = render(<>{deleteScheduledTaskToolCard.renderExpanded(context({ ...error, resultError: true }))}</>)
      expect(screen.getByText("failed")).toBeInTheDocument()
      expect(screen.getByText(/scheduled task not found|repository write access/)).toBeInTheDocument()
      unmount()
    }
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

  it("publishes success and error catalog examples", () => {
    expect(examples.map((example) => example.id)).toEqual(["deleted_task_details", "task_not_found"])
  })
})
