import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
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

  it("renders the Job link, kind, attention state, detail, step, age, and recommended action", () => {
    const parsedResult = {
      items: [
        {
          kind: "running_run_without_live_worker_evidence",
          severity: "alarm",
          attention_state: "auto_repairable",
          detail: "Run has no live worker heartbeat",
          age_label: "6m",
          step_kind: "implement",
          job_id: 4048,
          title: "Add plugin-aware tool cards",
          job_path: "/jobs/4048",
          repair_plan: { action: "mark_worker_died", auto_executable: true }
        }
      ]
    }

    render(<>{adminStuckJobsToolCard.renderExpanded(context({ parsedResult }))}</>)

    const link = screen.getByRole("link", { name: "JOB-4048 — Add plugin-aware tool cards" })
    expect(link).toHaveAttribute("href", "/jobs/4048")
    expect(screen.getByText("running run without live worker evidence")).toBeInTheDocument()
    expect(screen.getByText("auto repairable")).toBeInTheDocument()
    expect(screen.getByText("Run has no live worker heartbeat")).toBeInTheDocument()
    expect(screen.getByText("implement")).toBeInTheDocument()
    expect(screen.getByText("6m")).toBeInTheDocument()
    expect(screen.getByText("mark worker died")).toBeInTheDocument()
  })

  it("renders plain text when job_path is absent", () => {
    const parsedResult = { items: [{ kind: "x", job_id: 1 }] }
    render(<>{adminStuckJobsToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.queryByRole("link")).not.toBeInTheDocument()
    expect(screen.getByText("JOB-1")).toBeInTheDocument()
  })

  it("renders an explicit empty state for a well-formed empty list", () => {
    render(<>{adminStuckJobsToolCard.renderExpanded(context({ parsedResult: { items: [] } }))}</>)
    expect(screen.getByText("No stuck Jobs found.")).toBeInTheDocument()
  })

  it("falls back to null for a malformed payload", () => {
    expect(adminStuckJobsToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(adminStuckJobsToolCard.renderExpanded(context({ parsedResult: { oops: true } }))).toBeNull()
  })

  it("falls back to null for a non-object payload", () => {
    expect(adminStuckJobsToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
