import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import scheduleRecurringToolCard from "./schedule_recurring"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "schedule_recurring",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

const proposal = {
  pending_confirmation_id: 501,
  schedule_explanation: "Runs every Monday at 9:00 AM UTC",
  next_fire_at: "2026-09-08T09:00:00Z"
}

describe("schedule_recurring tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(scheduleRecurringToolCard.toolName).toBe("schedule_recurring")
  })

  it("summarizes the collapsed row with the cadence explanation", () => {
    expect(scheduleRecurringToolCard.collapsedSummary?.(context({ parsedResult: proposal }))).toBe(
      "Recurring task proposed: Runs every Monday at 9:00 AM UTC"
    )
  })

  it("falls back to the confirmation id when there is no explanation", () => {
    const parsedResult = { ...proposal, schedule_explanation: null }

    expect(scheduleRecurringToolCard.collapsedSummary?.(context({ parsedResult }))).toBe(
      "Recurring task proposed (confirmation #501)"
    )
  })

  it("renders the pending confirmation id, cadence, and first fire time", () => {
    render(<>{scheduleRecurringToolCard.renderExpanded(context({ parsedResult: proposal }))}</>)

    expect(screen.getByText("Recurring task proposed")).toBeInTheDocument()
    expect(screen.getByText("proposed")).toBeInTheDocument()
    expect(screen.getByText("Runs every Monday at 9:00 AM UTC")).toBeInTheDocument()
    expect(screen.getByText("#501")).toBeInTheDocument()
    expect(screen.getByText("2026-09-08T09:00:00Z")).toBeInTheDocument()
    expect(screen.getByText("Not created yet — awaiting operator confirmation.")).toBeInTheDocument()
  })

  it("renders without confirm or reject controls", () => {
    render(<>{scheduleRecurringToolCard.renderExpanded(context({ parsedResult: proposal }))}</>)

    expect(screen.queryAllByRole("button")).toHaveLength(0)
  })

  it("falls back to null when only the confirmation id is present", () => {
    const parsedResult = { pending_confirmation_id: 501 }

    expect(scheduleRecurringToolCard.collapsedSummary?.(context({ parsedResult }))).toBeNull()
    expect(scheduleRecurringToolCard.renderExpanded(context({ parsedResult }))).toBeNull()
  })

  it("falls back to null for a malformed payload", () => {
    const parsedResult = { oops: true }

    expect(scheduleRecurringToolCard.collapsedSummary?.(context({ parsedResult }))).toBeNull()
    expect(scheduleRecurringToolCard.renderExpanded(context({ parsedResult }))).toBeNull()
  })

  it("falls back to null for a non-object payload", () => {
    const parsedResult = "not json"

    expect(scheduleRecurringToolCard.collapsedSummary?.(context({ parsedResult }))).toBeNull()
    expect(scheduleRecurringToolCard.renderExpanded(context({ parsedResult }))).toBeNull()
  })
})
