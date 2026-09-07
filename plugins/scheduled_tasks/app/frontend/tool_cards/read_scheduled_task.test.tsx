import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import readScheduledTaskToolCard from "./read_scheduled_task"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "read_scheduled_task",
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
  state: "scheduled",
  cron_expression: "0 3 * * *",
  schedule_input: "Every day at 3am",
  schedule_explanation: "Runs daily at 3:00 AM UTC",
  schedule_timezone: "UTC",
  fire_at: null,
  pr_pileup_policy: "skip",
  enabled: true,
  last_fired_at: "2026-09-05T03:00:00Z",
  last_successful_fire_at: "2026-09-05T03:00:00Z",
  consecutive_failure_count: 0,
  next_fire_at: "2026-09-06T03:00:00Z",
  created_at: "2026-08-01T00:00:00Z",
  prompt: "Survey main for failing graders and open a repair Job if anything is red."
}

describe("read_scheduled_task tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(readScheduledTaskToolCard.toolName).toBe("read_scheduled_task")
  })

  it("summarizes the collapsed row with the label, id, and state", () => {
    const parsedResult = { scheduled_task: task }

    expect(readScheduledTaskToolCard.collapsedSummary?.(context({ parsedResult }))).toBe(
      "Nightly main-branch health check (#12, scheduled)"
    )
  })

  it("renders the schedule, repository, and firing history", () => {
    render(<>{readScheduledTaskToolCard.renderExpanded(context({ parsedResult: { scheduled_task: task } }))}</>)

    expect(screen.getByText("Nightly main-branch health check")).toBeInTheDocument()
    expect(screen.getByText("scheduled")).toBeInTheDocument()
    expect(screen.getByText("cron")).toBeInTheDocument()
    expect(screen.getByText("Runs daily at 3:00 AM UTC (UTC)")).toBeInTheDocument()
    expect(screen.getByText("tkadauke/syrus")).toBeInTheDocument()
    expect(screen.getByText("2026-09-06T03:00:00Z")).toBeInTheDocument()
    expect(screen.getByText("skip")).toBeInTheDocument()
  })

  it("puts the full prompt behind a disclosure", () => {
    render(<>{readScheduledTaskToolCard.renderExpanded(context({ parsedResult: { scheduled_task: task } }))}</>)

    expect(screen.getByText("Prompt")).toBeInTheDocument()
    expect(screen.getByText(task.prompt)).toBeInTheDocument()
  })

  it("renders a paused task and its failure count", () => {
    const parsedResult = { scheduled_task: { ...task, state: "paused", enabled: false, consecutive_failure_count: 2 } }

    render(<>{readScheduledTaskToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("paused")).toBeInTheDocument()
    expect(screen.getByText("disabled")).toBeInTheDocument()
    expect(screen.getByText("2 consecutive failures")).toBeInTheDocument()
  })

  it("renders without a prompt disclosure when the prompt is missing", () => {
    const parsedResult = { scheduled_task: { ...task, prompt: null } }

    render(<>{readScheduledTaskToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.queryByText("Prompt")).not.toBeInTheDocument()
  })

  it("falls back to null for a malformed payload", () => {
    const parsedResult = { oops: true }

    expect(readScheduledTaskToolCard.collapsedSummary?.(context({ parsedResult }))).toBeNull()
    expect(readScheduledTaskToolCard.renderExpanded(context({ parsedResult }))).toBeNull()
  })

  it("falls back to null when the task payload is missing required fields", () => {
    const parsedResult = { scheduled_task: { id: 12 } }

    expect(readScheduledTaskToolCard.collapsedSummary?.(context({ parsedResult }))).toBeNull()
    expect(readScheduledTaskToolCard.renderExpanded(context({ parsedResult }))).toBeNull()
  })

  it("falls back to null for a non-object payload", () => {
    const parsedResult = "not json"

    expect(readScheduledTaskToolCard.collapsedSummary?.(context({ parsedResult }))).toBeNull()
    expect(readScheduledTaskToolCard.renderExpanded(context({ parsedResult }))).toBeNull()
  })
})
