import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import resumeScheduledTaskToolCard from "./resume_scheduled_task"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "resume_scheduled_task",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

const resumed = { scheduled_task_id: 12, label: "Nightly main-branch health check", enabled: true }

describe("resume_scheduled_task tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(resumeScheduledTaskToolCard.toolName).toBe("resume_scheduled_task")
  })

  it("summarizes the collapsed row with the resumed label and id", () => {
    expect(resumeScheduledTaskToolCard.collapsedSummary?.(context({ parsedResult: resumed }))).toBe(
      "Resumed 'Nightly main-branch health check' (#12)"
    )
  })

  it("renders the resumed outcome", () => {
    render(<>{resumeScheduledTaskToolCard.renderExpanded(context({ parsedResult: resumed }))}</>)

    expect(screen.getByText("resumed")).toBeInTheDocument()
    expect(screen.getByText("#12")).toBeInTheDocument()
    expect(screen.getByText("Nightly main-branch health check")).toBeInTheDocument()
    expect(screen.getByText("This task is scheduled again and will fire on its next due tick.")).toBeInTheDocument()
  })

  it("falls back to null for a malformed payload", () => {
    const parsedResult = { oops: true }

    expect(resumeScheduledTaskToolCard.collapsedSummary?.(context({ parsedResult }))).toBeNull()
    expect(resumeScheduledTaskToolCard.renderExpanded(context({ parsedResult }))).toBeNull()
  })

  it("falls back to null for a non-object payload", () => {
    const parsedResult = "not json"

    expect(resumeScheduledTaskToolCard.collapsedSummary?.(context({ parsedResult }))).toBeNull()
    expect(resumeScheduledTaskToolCard.renderExpanded(context({ parsedResult }))).toBeNull()
  })
})
