import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import updateScheduledTaskToolCard from "./update_scheduled_task"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "update_scheduled_task",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

const task = {
  id: 12,
  repository_slug: "tkadauke/syrus",
  label: "Nightly main-branch health check",
  kind: "cron",
  state: "auto_paused",
  cron_expression: "0 5 * * *",
  schedule_input: "Every day at 5am",
  schedule_explanation: null,
  schedule_timezone: null,
  fire_at: null,
  pr_pileup_policy: "replace",
  enabled: false,
  consecutive_failure_count: 4,
  next_fire_at: "2026-09-07T05:00:00Z",
  prompt: "Check main and repair it."
}

describe("update_scheduled_task tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(updateScheduledTaskToolCard.toolName).toBe("update_scheduled_task")
  })

  it("summarizes the collapsed row as an update outcome", () => {
    const parsedResult = { scheduled_task: task }

    expect(updateScheduledTaskToolCard.collapsedSummary?.(context({ parsedResult }))).toBe(
      "Updated Nightly main-branch health check (#12)"
    )
  })

  it("renders the post-update snapshot including the auto-paused state", () => {
    render(<>{updateScheduledTaskToolCard.renderExpanded(context({ parsedResult: { scheduled_task: task } }))}</>)

    expect(screen.getByText("Updated scheduled task")).toBeInTheDocument()
    expect(screen.getByText("Nightly main-branch health check")).toBeInTheDocument()
    expect(screen.getByText("auto paused")).toBeInTheDocument()
    expect(screen.getByText("4 consecutive failures")).toBeInTheDocument()
    expect(screen.getByText("replace")).toBeInTheDocument()
  })

  it("falls back to the cron expression when there is no schedule explanation", () => {
    render(<>{updateScheduledTaskToolCard.renderExpanded(context({ parsedResult: { scheduled_task: task } }))}</>)

    expect(screen.getByText("0 5 * * *")).toBeInTheDocument()
  })

  it("shows the updated prompt behind a disclosure", () => {
    render(<>{updateScheduledTaskToolCard.renderExpanded(context({ parsedResult: { scheduled_task: task } }))}</>)

    expect(screen.getByText("Prompt")).toBeInTheDocument()
    expect(screen.getByText("Check main and repair it.")).toBeInTheDocument()
  })

  it("falls back to null for a malformed payload", () => {
    const parsedResult = { oops: true }

    expect(updateScheduledTaskToolCard.collapsedSummary?.(context({ parsedResult }))).toBeNull()
    expect(updateScheduledTaskToolCard.renderExpanded(context({ parsedResult }))).toBeNull()
  })

  it("falls back to null for a non-object payload", () => {
    const parsedResult = "not json"

    expect(updateScheduledTaskToolCard.collapsedSummary?.(context({ parsedResult }))).toBeNull()
    expect(updateScheduledTaskToolCard.renderExpanded(context({ parsedResult }))).toBeNull()
  })
})
