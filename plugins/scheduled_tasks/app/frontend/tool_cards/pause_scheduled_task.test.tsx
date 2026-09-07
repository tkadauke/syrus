import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import pauseScheduledTaskToolCard from "./pause_scheduled_task"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "pause_scheduled_task",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

const paused = { scheduled_task_id: 12, label: "Nightly main-branch health check", enabled: false }

describe("pause_scheduled_task tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(pauseScheduledTaskToolCard.toolName).toBe("pause_scheduled_task")
  })

  it("summarizes the collapsed row with the paused label and id", () => {
    expect(pauseScheduledTaskToolCard.collapsedSummary?.(context({ parsedResult: paused }))).toBe(
      "Paused 'Nightly main-branch health check' (#12)"
    )
  })

  it("renders the paused outcome", () => {
    render(<>{pauseScheduledTaskToolCard.renderExpanded(context({ parsedResult: paused }))}</>)

    expect(screen.getByText("paused")).toBeInTheDocument()
    expect(screen.getByText("#12")).toBeInTheDocument()
    expect(screen.getByText("Nightly main-branch health check")).toBeInTheDocument()
    expect(screen.getByText("This task will not fire again until it is resumed.")).toBeInTheDocument()
  })

  it("falls back to null for a malformed payload", () => {
    const parsedResult = { oops: true }

    expect(pauseScheduledTaskToolCard.collapsedSummary?.(context({ parsedResult }))).toBeNull()
    expect(pauseScheduledTaskToolCard.renderExpanded(context({ parsedResult }))).toBeNull()
  })

  it("falls back to null for a non-object payload", () => {
    const parsedResult = "not json"

    expect(pauseScheduledTaskToolCard.collapsedSummary?.(context({ parsedResult }))).toBeNull()
    expect(pauseScheduledTaskToolCard.renderExpanded(context({ parsedResult }))).toBeNull()
  })
})
