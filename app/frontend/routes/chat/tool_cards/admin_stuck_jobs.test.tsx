import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import { normalizedToolCardParsedResult, normalizedToolName } from "../toolRendering"
import adminStuckJobsToolCard from "./admin_stuck_jobs"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "admin_stuck_jobs",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

describe("admin_stuck_jobs tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(adminStuckJobsToolCard.toolName).toBe("admin_stuck_jobs")
  })

  it("summarizes the collapsed row with a count", () => {
    const parsedResult = { items: [{ kind: "a" }, { kind: "b" }] }
    expect(adminStuckJobsToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("2 stuck items")
  })

  it("renders every stuck-item field, entity links, markdown detail, and repair steps", () => {
    const parsedResult = {
      items: [
        {
          kind: "running_run_without_live_worker_evidence",
          severity: "alarm",
          reconciler_severity: "critical",
          attention_state: "auto_repairable",
          detail: `Run has **no live worker** heartbeat. ${"More diagnostic context. ".repeat(40)}`,
          age_label: "6m",
          age_seconds: 360,
          step_kind: "implement",
          id: 4048,
          state: "running",
          job_id: 4048,
          job_state: "running",
          title: "Add plugin-aware tool cards",
          job_path: "/jobs/4048",
          workflow_id: 900,
          workflow_slug: "initial-attempt",
          workflow_path: "/jobs/4048?tab=workflows#workflow-900",
          workflow_state: "running",
          workflow_trigger_kind: "initial",
          run_id: 501,
          run_state: "running",
          last_heartbeat_at: "2026-10-19T00:00:00Z",
          has_transcript: true,
          issue: { explanation: "Worker disappeared" },
          repair_plan: {
            issue_kind: "running_run_without_live_worker_evidence",
            action: "mark_worker_died",
            auto_executable: true,
            target_type: "Run",
            target_id: 501,
            affected_ids: { run_id: 501 },
            execution_steps: ["Mark the Run failed", "Continue the Workflow"],
            preconditions: { state: "running" },
            retry_after: "2026-10-19T00:05:00Z",
            check_after: "2026-10-19T00:06:00Z",
            reason: "The **worker heartbeat** expired."
          },
          repair_execution: { action: "mark_worker_died", target_type: "Run", target_id: 501, status: "applied", message: "Run marked failed" }
        }
      ]
    }

    render(<>{adminStuckJobsToolCard.renderExpanded(context({ parsedResult }))}</>)

    const link = screen.getByRole("link", { name: "JOB-4048 — Add plugin-aware tool cards" })
    expect(link).toHaveAttribute("href", "/jobs/4048")
    expect(screen.getByRole("link", { name: "WF-900" })).toHaveAttribute("href", "/jobs/4048?tab=workflows#workflow-900")
    expect(screen.getByText("initial-attempt")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "RUN-501" })).toHaveAttribute("href", "/jobs/4048?tab=workflows#workflow-900")
    expect(screen.getByText("running run without live worker evidence")).toBeInTheDocument()
    expect(screen.getByText("auto repairable")).toBeInTheDocument()
    expect(screen.getByText("no live worker")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Show more" })).toBeInTheDocument()
    expect(screen.getByText("implement")).toBeInTheDocument()
    expect(screen.getByText("6m")).toBeInTheDocument()
    expect(screen.getByText("mark worker died")).toBeInTheDocument()
    expect(screen.getByText("Mark the Run failed")).toBeInTheDocument()
    expect(screen.getByText("Continue the Workflow")).toBeInTheDocument()
    expect(screen.getByText('{"explanation":"Worker disappeared"}')).toBeInTheDocument()
    expect(screen.getByText("applied")).toBeInTheDocument()
    expect(screen.getByText("Run marked failed")).toBeInTheDocument()
    expect(screen.getByText("critical")).toBeInTheDocument()
    expect(screen.getAllByText("running").length).toBeGreaterThanOrEqual(3)
    expect(document.querySelector('td[data-label="Repair plan"]')).toBeInTheDocument()
  })

  it("derives the Job link when job_path is absent", () => {
    const parsedResult = { items: [{ kind: "x", job_id: 1 }] }
    render(<>{adminStuckJobsToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByRole("link", { name: "JOB-1" })).toHaveAttribute("href", "/jobs/1")
  })

  it("renders an explicit empty state for a well-formed empty list", () => {
    render(<>{adminStuckJobsToolCard.renderExpanded(context({ parsedResult: { items: [] } }))}</>)
    expect(screen.getByText("No stuck Jobs found.")).toBeInTheDocument()
  })

  it("renders a generic error without leaking the raw result", () => {
    const errorContext = context({ resultError: true, resultBody: "token=super-secret", parsedResult: { items: [] } })
    render(<>{adminStuckJobsToolCard.renderExpanded(errorContext)}</>)
    expect(screen.getByText("Could not load stuck Jobs.")).toBeInTheDocument()
    expect(screen.queryByText(/super-secret/)).not.toBeInTheDocument()
    expect(adminStuckJobsToolCard.collapsedSummary?.(errorContext)).toBe("Could not load stuck Jobs")
  })

  it.each([
    ["mcp__syrus-chat-sidecar__admin_stuck_jobs", { structured_content: { items: [{ kind: "structured" }] } }],
    ["admin_stuck_jobs", { content: [{ type: "text", text: JSON.stringify({ items: [{ kind: "text_json" }] }) }] }]
  ])("normalizes %s result envelopes identically", (rawName, envelope) => {
    const parsedResult = normalizedToolCardParsedResult(envelope)
    const normalizedContext = context({ toolName: normalizedToolName(rawName), parsedResult })
    expect(normalizedContext.toolName).toBe("admin_stuck_jobs")
    expect(adminStuckJobsToolCard.collapsedSummary?.(normalizedContext)).toBe("1 stuck item")
    render(<>{adminStuckJobsToolCard.renderExpanded(normalizedContext)}</>)
    expect(screen.getByText(rawName.startsWith("mcp__") ? "structured" : "text json")).toBeInTheDocument()
  })

  it("falls back to null for a malformed payload", () => {
    expect(adminStuckJobsToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(adminStuckJobsToolCard.renderExpanded(context({ parsedResult: { oops: true } }))).toBeNull()
  })

  it("falls back to null for a non-object payload", () => {
    expect(adminStuckJobsToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
