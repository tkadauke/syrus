import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import adminMaintenanceTasksToolCard from "./admin_maintenance_tasks"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "admin_maintenance_tasks",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

function task(overrides: Record<string, unknown> = {}) {
  return {
    id: 7,
    definition_key: "backfill_widgets",
    task_key: "backfill_widgets:2026-09-01",
    state: "running",
    recurrence: "one_off",
    category: "backfill",
    title: "Backfill widget owners",
    summary: "Backfills owner_id on legacy widgets.",
    current_step_key: "backfill",
    current_step_title: "Backfilling rows",
    total_units: 1000,
    completed_units: 400,
    failed_units: 0,
    progress_percent: 40,
    last_error: null,
    pending_reason: null,
    ...overrides
  }
}

describe("admin_maintenance_tasks tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(adminMaintenanceTasksToolCard.toolName).toBe("admin_maintenance_tasks")
  })

  it("summarizes a task list with a count", () => {
    const parsedResult = { tasks: [ task(), task({ id: 8, title: "Rebuild search index" }) ] }
    expect(adminMaintenanceTasksToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("2 maintenance tasks")
  })

  it("summarizes a single task with its title and state", () => {
    const parsedResult = { task: task() }
    expect(adminMaintenanceTasksToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("Backfill widget owners (running)")
  })

  it("renders a task list as a dense table", () => {
    const parsedResult = { tasks: [ task(), task({ id: 8, title: "Rebuild search index", state: "paused", category: "index", progress_percent: 10, failed_units: 2 }) ] }
    render(<>{adminMaintenanceTasksToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("Backfill widget owners")).toBeInTheDocument()
    expect(screen.getByText("Rebuild search index")).toBeInTheDocument()
    expect(screen.getByText("running")).toBeInTheDocument()
    expect(screen.getByText("paused")).toBeInTheDocument()
    expect(screen.getByText("40%")).toBeInTheDocument()
    expect(screen.getByText("10%")).toBeInTheDocument()
    expect(screen.getByText("2")).toBeInTheDocument()
  })

  it("renders an explicit empty state for a well-formed empty list", () => {
    render(<>{adminMaintenanceTasksToolCard.renderExpanded(context({ parsedResult: { tasks: [] } }))}</>)
    expect(screen.getByText("No maintenance tasks found.")).toBeInTheDocument()
  })

  it("renders a single task's status, counts, and current step", () => {
    render(<>{adminMaintenanceTasksToolCard.renderExpanded(context({ parsedResult: { task: task() } }))}</>)

    expect(screen.getByText("running")).toBeInTheDocument()
    expect(screen.getByText("backfill")).toBeInTheDocument()
    expect(screen.getByText("one_off")).toBeInTheDocument()
    expect(screen.getByText("Backfill widget owners")).toBeInTheDocument()
    expect(screen.getByText("Backfilling rows")).toBeInTheDocument()
    expect(screen.getByText("40%")).toBeInTheDocument()
    expect(screen.getByText("400 / 1000")).toBeInTheDocument()
  })

  it("surfaces the last error and a recommended follow-up for a failed task", () => {
    const parsedResult = { task: task({ state: "failed", last_error: "PG::ConnectionBad: could not connect", failed_units: 3 }) }
    render(<>{adminMaintenanceTasksToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("failed")).toBeInTheDocument()
    expect(screen.getByText("Last error")).toBeInTheDocument()
    expect(screen.getByText("PG::ConnectionBad: could not connect")).toBeInTheDocument()
    expect(screen.getByText("Follow-up")).toBeInTheDocument()
    expect(screen.getByText("Investigate the last error, then resume or cancel.")).toBeInTheDocument()
  })

  it("surfaces the pending reason for a paused task", () => {
    const parsedResult = { task: task({ state: "paused", pending_reason: "Waiting for downstream table lock to clear." }) }
    render(<>{adminMaintenanceTasksToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("Follow-up")).toBeInTheDocument()
    expect(screen.getByText("Waiting for downstream table lock to clear.")).toBeInTheDocument()
  })

  it("omits last error, pending reason, and follow-up sections when the task carries none", () => {
    render(<>{adminMaintenanceTasksToolCard.renderExpanded(context({ parsedResult: { task: task() } }))}</>)

    expect(screen.queryByText("Last error")).not.toBeInTheDocument()
    expect(screen.queryByText("Follow-up")).not.toBeInTheDocument()
  })

  it("falls back to null for a malformed or error payload", () => {
    expect(adminMaintenanceTasksToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(adminMaintenanceTasksToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
    expect(adminMaintenanceTasksToolCard.renderExpanded(context({ resultError: true, parsedResult: null, resultBody: "Error: maintenance task not found" }))).toBeNull()
  })
})
