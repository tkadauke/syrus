import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import { redactToolCardValue } from "@app/toolCardSecurity"
import { normalizedToolCardParsedResult, normalizedToolName } from "../toolRendering"
import adminMaintenanceTasksToolCard from "./admin_maintenance_tasks"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return { toolName: "admin_maintenance_tasks", resultBody: "", resultError: false, parsedResult: null, ...overrides }
}

function task(overrides: Record<string, unknown> = {}) {
  return {
    id: 7,
    definition_key: "backfill_widgets",
    task_key: "backfill_widgets:2026-09-01",
    state: "running",
    recurrence: "one_off",
    category: "backfill",
    title:
      "Backfill widget owners with a deliberately long title that must wrap cleanly instead of truncating around one hundred and thirty-one characters on narrow screens",
    summary: "Backfills **owner_id** on legacy widgets.",
    trigger_kind: "manual",
    trigger_key: "operator",
    required_role: "admin",
    current_step_key: "backfill",
    current_step_title: "Backfilling rows",
    total_units: 1000,
    completed_units: 400,
    failed_units: 0,
    progress_percent: 40,
    eta_seconds: 90,
    started_at: "2026-09-01T00:00:00Z",
    finished_at: null,
    paused_at: null,
    cancelled_at: null,
    dismissed_at: null,
    last_error: null,
    pending_reason: null,
    checkpoint: { last_id: 400 },
    documentation: "# Runbook\n\nUse **carefully**.",
    steps: [{ key: "backfill", title: "Backfill records", description: "Updates legacy rows." }],
    events: [
      {
        id: 91,
        level: "info",
        step_key: "backfill",
        step_title: "Backfill records",
        message: "Updated batch",
        units_done: 400,
        units_total: 1000,
        created_at: "2026-09-01T00:01:00Z"
      }
    ],
    requested_by: { id: 3, display_name: "Ada Admin" },
    paths: { admin: "/admin/maintenance_tasks/7", api: "/api/v1/app/admin/maintenance_tasks/7" },
    ...overrides
  }
}

describe("admin_maintenance_tasks tool card", () => {
  it("registers under the exact MCP tool name", () => expect(adminMaintenanceTasksToolCard.toolName).toBe("admin_maintenance_tasks"))

  it("renders every list-row field in a responsive table without truncating titles", () => {
    render(<>{adminMaintenanceTasksToolCard.renderExpanded(context({ parsedResult: { tasks: [task()] } }))}</>)
    expect(screen.getAllByText(/Backfill widget owners with a deliberately long title/)[0]).toHaveClass("whitespace-normal", "break-words")
    for (const value of [
      "backfill_widgets",
      "backfill_widgets:2026-09-01",
      "manual",
      "operator",
      "admin",
      "backfill",
      "Backfilling rows",
      "1000",
      "400",
      "0",
      "40%",
      "90s",
      "Ada Admin (#3)",
      "/api/v1/app/admin/maintenance_tasks/7"
    ]) {
      expect(screen.getAllByText(value).length).toBeGreaterThan(0)
    }
    expect(screen.getByText("owner_id")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Open task" })).toHaveAttribute("href", "/admin/maintenance_tasks/7")
    expect(screen.getByRole("table")).toHaveClass("block")
  })

  it("renders read-only detail fields, markdown, checkpoint, events, and redacted log previews", () => {
    const redacted = redactToolCardValue(
      task({
        last_error: "authorization=secret-token-value",
        pending_reason: "Waiting for **approval**.",
        events: [{ id: 92, level: "error", step_key: "backfill", step_title: "Backfill records", message: "token=secret-token-value failed", units_done: 401 }]
      })
    )
    render(<>{adminMaintenanceTasksToolCard.renderExpanded(context({ input: { action: "read", task_id: 7 }, parsedResult: { task: redacted } }))}</>)
    expect(screen.getByText("read")).toBeInTheDocument()
    expect(screen.getAllByText("7").length).toBeGreaterThan(0)
    expect(screen.getByText("Runbook")).toBeInTheDocument()
    expect(screen.getByText(/"last_id": 400/)).toBeInTheDocument()
    expect(screen.getByText("Event #92")).toBeInTheDocument()
    expect(screen.getByText("authorization=[redacted]")).toBeInTheDocument()
    expect(screen.getByText("token=[redacted] failed")).toBeInTheDocument()
    expect(screen.queryByText(/secret-token-value/)).not.toBeInTheDocument()
  })

  it("uses the shared pending-action card and echoes mutation inputs", () => {
    const parsedResult = { pending_action_id: 501, state: "pending", message: "Pause maintenance task #7?" }
    render(<>{adminMaintenanceTasksToolCard.renderExpanded(context({ input: { action: "pause", task_id: 7, state: "running" }, parsedResult }))}</>)
    expect(screen.getByText("Pending action #501")).toBeInTheDocument()
    expect(screen.getByText("pause")).toBeInTheDocument()
    expect(screen.getByText("7")).toBeInTheDocument()
    expect(screen.getByText("running")).toBeInTheDocument()
    expect(adminMaintenanceTasksToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("Pause maintenance task #7?")
  })

  it("renders tool errors with input context", () => {
    render(
      <>
        {adminMaintenanceTasksToolCard.renderExpanded(
          context({ input: { action: "read", task_id: 999 }, resultError: true, resultBody: "maintenance task not found", parsedResult: null })
        )}
      </>
    )
    expect(screen.getByText("Tool error")).toBeInTheDocument()
    expect(screen.getByText("maintenance task not found")).toBeInTheDocument()
    expect(screen.getByText("read")).toBeInTheDocument()
    expect(screen.getByText("999")).toBeInTheDocument()
  })

  it("renders empty filtered list results with their invocation inputs", () => {
    render(<>{adminMaintenanceTasksToolCard.renderExpanded(context({ input: { action: "list", state: "paused", limit: 25 }, parsedResult: { tasks: [] } }))}</>)
    expect(screen.getByText("No maintenance tasks found.")).toBeInTheDocument()
    expect(screen.getByText("list")).toBeInTheDocument()
    expect(screen.getByText("paused")).toBeInTheDocument()
    expect(screen.getByText("25")).toBeInTheDocument()
  })

  it("renders list and discover inputs with populated successful results", () => {
    const listView = render(
      <>{adminMaintenanceTasksToolCard.renderExpanded(context({ input: { action: "list", state: "running", limit: 1 }, parsedResult: { tasks: [task()] } }))}</>
    )
    expect(screen.getByText("list")).toBeInTheDocument()
    expect(screen.getAllByText("running").length).toBeGreaterThan(0)
    expect(screen.getByText("1")).toBeInTheDocument()
    listView.unmount()

    render(<>{adminMaintenanceTasksToolCard.renderExpanded(context({ input: { action: "discover" }, parsedResult: { tasks: [task()] } }))}</>)
    expect(screen.getByText("discover")).toBeInTheDocument()
  })

  it.each([
    ["direct", task()],
    ["structured content", { structured_content: { task: task() } }],
    ["text content", { content: [{ type: "text", text: JSON.stringify({ task: task() }) }], structured_content: null }]
  ])("normalizes %s results for namespaced agent calls", (_label, envelope) => {
    const parsedResult = _label === "direct" ? { task: envelope } : envelope
    expect(normalizedToolName("mcp__syrus-chat-sidecar__admin_maintenance_tasks")).toBe("admin_maintenance_tasks")
    expect(
      adminMaintenanceTasksToolCard.collapsedSummary?.(
        context({ toolName: "mcp__syrus-chat-sidecar__admin_maintenance_tasks", parsedResult: normalizedToolCardParsedResult(parsedResult) })
      )
    ).toContain("Backfill widget owners")
  })

  it("falls back for malformed successful payloads", () => {
    expect(adminMaintenanceTasksToolCard.renderExpanded(context({ parsedResult: { oops: true } }))).toBeNull()
  })
})
