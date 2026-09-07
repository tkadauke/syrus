import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import listWakeupsToolCard from "./list_wakeups"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return { toolName: "list_wakeups", resultBody: "", resultError: false, parsedResult: null, ...overrides }
}

describe("list_wakeups tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(listWakeupsToolCard.toolName).toBe("list_wakeups")
  })

  it("summarizes the wakeup count", () => {
    const parsedResult = { wakeups: [{ id: 7, fire_at: "2026-09-07T12:00:00Z" }] }
    expect(listWakeupsToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("1 wakeup")
  })

  it("renders a friendly empty state for a well-formed empty list", () => {
    const parsedResult = { wakeups: [] }

    render(<>{listWakeupsToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("No pending wakeups in this chat.")).toBeInTheDocument()
  })

  it("renders each wakeup's id, fire time, remaining delay, and prompt preview", () => {
    const parsedResult = {
      wakeups: [{ id: 7, fire_at: "2026-09-07T12:00:00Z", delay_remaining_minutes: 42, prompt_preview: "Check JOB-4222 mergeability" }]
    }

    render(<>{listWakeupsToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByRole("table")).toBeInTheDocument()
    expect(screen.getByText("#7")).toBeInTheDocument()
    expect(screen.getByText("2026-09-07T12:00:00Z")).toBeInTheDocument()
    expect(screen.getByText("42 min")).toBeInTheDocument()
    expect(screen.getByText("Check JOB-4222 mergeability")).toBeInTheDocument()
  })

  it("falls back to null for a malformed payload", () => {
    const parsedResult = { oops: true }
    expect(listWakeupsToolCard.collapsedSummary?.(context({ parsedResult }))).toBeNull()
    expect(listWakeupsToolCard.renderExpanded(context({ parsedResult }))).toBeNull()
  })

  it("falls back to null for a non-object payload", () => {
    const parsedResult = "not json"
    expect(listWakeupsToolCard.collapsedSummary?.(context({ parsedResult }))).toBeNull()
    expect(listWakeupsToolCard.renderExpanded(context({ parsedResult }))).toBeNull()
  })
})
