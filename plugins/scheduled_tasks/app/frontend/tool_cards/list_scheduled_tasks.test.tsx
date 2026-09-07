import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import listScheduledTasksToolCard from "./list_scheduled_tasks"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "list_scheduled_tasks",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

const cronTask = {
  id: 12,
  repository_slug: "tkadauke/syrus",
  label: "Nightly main-branch health check",
  kind: "cron",
  state: "scheduled",
  cron_expression: "0 3 * * *",
  schedule_input: "Every day at 3am",
  schedule_explanation: "Runs daily at 3:00 AM UTC",
  schedule_timezone: "UTC",
  fire_at: null,
  pr_pileup_policy: "skip",
  enabled: true,
  last_fired_at: "2026-09-05T03:00:00Z",
  consecutive_failure_count: 0,
  next_fire_at: "2026-09-06T03:00:00Z",
  created_at: "2026-08-01T00:00:00Z"
}

const oneShotTask = {
  id: 13,
  repository_slug: "tkadauke/syrus",
  label: "One-off dependency sweep",
  kind: "one_shot",
  state: "fired",
  cron_expression: null,
  schedule_explanation: null,
  fire_at: "2026-09-01T12:00:00Z",
  enabled: false,
  consecutive_failure_count: 0,
  next_fire_at: null
}

describe("list_scheduled_tasks tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(listScheduledTasksToolCard.toolName).toBe("list_scheduled_tasks")
  })

  it("summarizes the collapsed row with a task count", () => {
    const parsedResult = { tasks: [cronTask, oneShotTask] }

    expect(listScheduledTasksToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("2 scheduled tasks")
  })

  it("singularizes the collapsed summary for one task", () => {
    expect(listScheduledTasksToolCard.collapsedSummary?.(context({ parsedResult: { tasks: [cronTask] } }))).toBe("1 scheduled task")
  })

  it("renders a row per task with state, kind, cadence, and next fire", () => {
    render(<>{listScheduledTasksToolCard.renderExpanded(context({ parsedResult: { tasks: [cronTask, oneShotTask] } }))}</>)

    expect(screen.getByText("Nightly main-branch health check")).toBeInTheDocument()
    expect(screen.getByText("scheduled")).toBeInTheDocument()
    expect(screen.getByText("cron")).toBeInTheDocument()
    expect(screen.getByText("Runs daily at 3:00 AM UTC")).toBeInTheDocument()
    expect(screen.getByText("2026-09-06T03:00:00Z")).toBeInTheDocument()

    expect(screen.getByText("One-off dependency sweep")).toBeInTheDocument()
    expect(screen.getByText("fired")).toBeInTheDocument()
    expect(screen.getByText("one shot")).toBeInTheDocument()
    // one_shot tasks fall back to fire_at for both cadence and next fire.
    expect(screen.getByText("Once at 2026-09-01T12:00:00Z")).toBeInTheDocument()
    expect(screen.getByText("2026-09-01T12:00:00Z")).toBeInTheDocument()
  })

  it("flags a task with consecutive failures", () => {
    const parsedResult = { tasks: [{ ...cronTask, state: "auto_paused", consecutive_failure_count: 3 }] }

    render(<>{listScheduledTasksToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("auto paused")).toBeInTheDocument()
    expect(screen.getByText("3 consecutive failures")).toBeInTheDocument()
  })

  it("renders a friendly empty state for no tasks", () => {
    render(<>{listScheduledTasksToolCard.renderExpanded(context({ parsedResult: { tasks: [] } }))}</>)

    expect(screen.getByText("No scheduled tasks for this repository.")).toBeInTheDocument()
  })

  it("falls back to null for a malformed payload", () => {
    const parsedResult = { oops: true }

    expect(listScheduledTasksToolCard.collapsedSummary?.(context({ parsedResult }))).toBeNull()
    expect(listScheduledTasksToolCard.renderExpanded(context({ parsedResult }))).toBeNull()
  })

  it("falls back to null for a non-object payload", () => {
    const parsedResult = "not json"

    expect(listScheduledTasksToolCard.collapsedSummary?.(context({ parsedResult }))).toBeNull()
    expect(listScheduledTasksToolCard.renderExpanded(context({ parsedResult }))).toBeNull()
  })
})
