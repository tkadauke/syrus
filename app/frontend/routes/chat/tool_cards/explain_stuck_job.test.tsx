import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import explainStuckJobToolCard from "./explain_stuck_job"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "explain_stuck_job",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

const FULL_PAYLOAD = {
  job: { id: 5, slug: "JOB-5", state: "running", issue_title: "Fix the thing" },
  stuck: true,
  recommended_action: { action: "inspect_logs", reason: "A running Run has a stale heartbeat.", run_id: 9 },
  human_summary: "JOB-5 is running; latest workflow WF-3 is running (initial). Recommended action: inspect_logs.",
  workflows: { latest: { id: 3, state: "running", trigger_kind: "initial" }, active: [{ id: 3 }], queued: [], failed: [] },
  runs: { latest: { id: 9 }, active: [{ id: 9 }], failed: [], heartbeat: [{ run_id: 9, stale_for_admin: true }] },
  dependencies: { pending: [], unsatisfied: [], multiple_leaf_dependencies: [], redundant_transitive_dependencies: [] },
  landing: { mergeability: { github_state: "clean", local_state: "clean" }, pr_checks: { state: "passing" }, commits_behind_base: 0 },
  work_units: { active: [{ id: 1 }], recent: [{ id: 1 }] }
}

describe("explain_stuck_job tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(explainStuckJobToolCard.toolName).toBe("explain_stuck_job")
  })

  it("summarizes the collapsed row with the slug and stuck flag", () => {
    expect(explainStuckJobToolCard.collapsedSummary?.(context({ parsedResult: FULL_PAYLOAD }))).toBe("JOB-5: stuck")
  })

  it("renders the headline, recommended action, human summary, and diagnostic sections", () => {
    render(<>{explainStuckJobToolCard.renderExpanded(context({ parsedResult: FULL_PAYLOAD }))}</>)

    expect(screen.getByText("JOB-5")).toBeInTheDocument()
    expect(screen.getByText("running")).toBeInTheDocument()
    expect(screen.getByText("stuck")).toBeInTheDocument()
    expect(screen.getByText("Fix the thing")).toBeInTheDocument()
    expect(screen.getByText("inspect logs")).toBeInTheDocument()
    expect(screen.getByText("A running Run has a stale heartbeat.")).toBeInTheDocument()
    expect(screen.getByText(/latest workflow WF-3/)).toBeInTheDocument()
    expect(screen.getByText("Workflows")).toBeInTheDocument()
    expect(screen.getByText(/latest running \(initial\) · 1 active/)).toBeInTheDocument()
    expect(screen.getByText("Runs")).toBeInTheDocument()
    expect(screen.getByText(/1 stale heartbeat/)).toBeInTheDocument()
    expect(screen.getByText("Landing")).toBeInTheDocument()
    expect(screen.getByText(/GitHub: clean/)).toBeInTheDocument()
  })

  it("marks a not-stuck Job accordingly", () => {
    const parsedResult = { ...FULL_PAYLOAD, stuck: false }
    render(<>{explainStuckJobToolCard.renderExpanded(context({ parsedResult }))}</>)
    expect(screen.getByText("not stuck")).toBeInTheDocument()
  })

  it("omits optional sections when fields are missing", () => {
    const parsedResult = { job: { id: 5, state: "running" }, stuck: false }
    render(<>{explainStuckJobToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("JOB-5")).toBeInTheDocument()
    expect(screen.queryByText("Diagnostics")).not.toBeInTheDocument()
    expect(screen.queryByText("Workflows")).not.toBeInTheDocument()
  })

  it("falls back to null for a malformed payload (missing job object)", () => {
    expect(explainStuckJobToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(explainStuckJobToolCard.renderExpanded(context({ parsedResult: { oops: true } }))).toBeNull()
  })

  it("falls back to null for a non-object payload", () => {
    expect(explainStuckJobToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
