import { fireEvent, render, screen } from "@testing-library/react"
import { beforeEach, describe, expect, it, vi } from "vitest"
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
  schedule_expression: "daily at 03:00",
  schedule_explanation: "Runs daily at 3:00 AM UTC",
  schedule_timezone: "UTC",
  fire_at: "2026-09-06T02:55:00Z",
  pr_pileup_policy: "skip",
  enabled: true,
  last_fired_at: "2026-09-05T03:00:00Z",
  last_successful_fire_at: "2026-09-04T03:00:00Z",
  prompt: "Check **main** and https://example.test/runbook before filing JOB-42. ".repeat(20),
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
  beforeEach(() => {
    Object.assign(navigator, {
      clipboard: { writeText: vi.fn().mockResolvedValue(undefined) }
    })
  })

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

  it("renders every task field with linked labels and repositories", () => {
    render(<>{listScheduledTasksToolCard.renderExpanded(context({ parsedResult: { tasks: [cronTask, oneShotTask] } }))}</>)

    expect(screen.getAllByRole("link", { name: "Nightly main-branch health check" })[0]).toHaveAttribute("href", "/scheduled_tasks/12")
    fireEvent.click(screen.getAllByRole("button", { name: "Copy TASK-12 to clipboard" })[0])
    expect(navigator.clipboard.writeText).toHaveBeenCalledWith("TASK-12")
    expect(screen.getAllByText("scheduled").length).toBeGreaterThan(0)
    expect(screen.getAllByText("cron").length).toBeGreaterThan(0)
    expect(screen.getAllByText("Every day at 3am").length).toBeGreaterThan(0)
    expect(screen.getAllByText("Runs daily at 3:00 AM UTC").length).toBeGreaterThan(0)
    expect(screen.getAllByText("0 3 * * *").length).toBeGreaterThan(0)
    expect(screen.getAllByText("daily at 03:00").length).toBeGreaterThan(0)
    expect(screen.getAllByText("UTC").length).toBeGreaterThan(0)
    expect(screen.getAllByText("2026-09-06T03:00:00Z").length).toBeGreaterThan(0)
    expect(screen.getAllByText(/2026-09-06T02:55:00Z/).length).toBeGreaterThan(0)
    expect(screen.getAllByRole("link", { name: "tkadauke/syrus" })[0]).toHaveAttribute("href", "https://github.com/tkadauke/syrus")
    expect(screen.getAllByText("2026-09-05T03:00:00Z").length).toBeGreaterThan(0)
    expect(screen.getAllByText(/2026-09-04T03:00:00Z/).length).toBeGreaterThan(0)
    expect(screen.getAllByText(/2026-08-01T00:00:00Z/).length).toBeGreaterThan(0)
    expect(screen.getAllByText("skip").length).toBeGreaterThan(0)
    expect(screen.getAllByText("enabled").length).toBeGreaterThan(0)
    expect(screen.getAllByText("Prompt").length).toBeGreaterThan(0)
    expect(screen.getAllByRole("button", { name: "Show more" }).length).toBeGreaterThan(0)

    expect(screen.getAllByText("One-off dependency sweep").length).toBeGreaterThan(0)
    expect(screen.getAllByText("fired").length).toBeGreaterThan(0)
    expect(screen.getAllByText("one shot").length).toBeGreaterThan(0)
    expect(screen.getAllByText(/2026-09-01T12:00:00Z/).length).toBeGreaterThan(0)
  })

  it("uses stacked mobile rows and a fixed wrapping desktop table", () => {
    const { container } = render(<>{listScheduledTasksToolCard.renderExpanded(context({ parsedResult: { tasks: [cronTask] } }))}</>)
    expect(container.querySelector("ul.sm\\:hidden")).toBeInTheDocument()
    expect(container.querySelector("div.sm\\:block table.table-fixed")).toBeInTheDocument()
    expect(container.querySelector(".overflow-x-auto")).not.toBeInTheDocument()
    expect(container.querySelector("td.break-words")).toBeInTheDocument()
  })

  it("shows all redacted input filters and accepts provider envelopes", () => {
    const parsedResult = { structured_content: { tasks: [cronTask] } }
    render(
      <>{listScheduledTasksToolCard.renderExpanded(context({ input: { state: "scheduled", enabled: true, api_token: "super-secret-value" }, parsedResult }))}</>
    )

    expect(screen.getByText("state")).toBeInTheDocument()
    expect(screen.getAllByText("scheduled").length).toBeGreaterThan(0)
    expect(screen.getByText("api token")).toBeInTheDocument()
    expect(screen.getByText("[redacted]")).toBeInTheDocument()
  })

  it.each([{ result: { tasks: [cronTask] } }, { data: { tasks: [cronTask] } }, { content: [{ type: "text", text: JSON.stringify({ tasks: [cronTask] }) }] }])(
    "parses differently shaped result envelopes",
    (parsedResult) => {
      expect(listScheduledTasksToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("1 scheduled task")
    }
  )

  it("renders structured and plain errors through the shared error card", () => {
    const { rerender } = render(
      <>{listScheduledTasksToolCard.renderExpanded(context({ parsedResult: { error: { message: "No access" } }, resultError: true }))}</>
    )
    expect(screen.getByText("No access")).toBeInTheDocument()
    rerender(<>{listScheduledTasksToolCard.renderExpanded(context({ parsedResult: null, resultBody: "Provider failed", resultError: true }))}</>)
    expect(screen.getByText("Provider failed")).toBeInTheDocument()
  })

  it("flags a task with consecutive failures", () => {
    const parsedResult = { tasks: [{ ...cronTask, state: "auto_paused", consecutive_failure_count: 3 }] }

    render(<>{listScheduledTasksToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getAllByText("auto paused").length).toBeGreaterThan(0)
    expect(screen.getAllByText("3 consecutive failures").length).toBeGreaterThan(0)
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
