import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import scheduleWakeupToolCard from "./schedule_wakeup"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return { toolName: "schedule_wakeup", resultBody: "", resultError: false, parsedResult: null, ...overrides }
}

describe("schedule_wakeup tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(scheduleWakeupToolCard.toolName).toBe("schedule_wakeup")
  })

  it("summarizes the fire time", () => {
    const parsedResult = { wakeup_id: 7, fire_at: "2026-09-07T12:00:00Z", message: "Wakeup scheduled for 2026-09-07T12:00:00Z" }
    expect(scheduleWakeupToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("Wakeup scheduled for 2026-09-07T12:00:00Z")
  })

  it("renders the wakeup id and fire time", () => {
    const parsedResult = { wakeup_id: 7, fire_at: "2026-09-07T12:00:00Z" }

    render(<>{scheduleWakeupToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("#7")).toBeInTheDocument()
    expect(screen.getByText("2026-09-07T12:00:00Z")).toBeInTheDocument()
  })

  it("falls back to null for a malformed payload", () => {
    const parsedResult = { oops: true }
    expect(scheduleWakeupToolCard.collapsedSummary?.(context({ parsedResult }))).toBeNull()
    expect(scheduleWakeupToolCard.renderExpanded(context({ parsedResult }))).toBeNull()
  })

  it("falls back to null for a non-object payload", () => {
    const parsedResult = "not json"
    expect(scheduleWakeupToolCard.collapsedSummary?.(context({ parsedResult }))).toBeNull()
    expect(scheduleWakeupToolCard.renderExpanded(context({ parsedResult }))).toBeNull()
  })
})
