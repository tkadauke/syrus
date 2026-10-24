import { fireEvent, render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import { normalizedToolName, toolResultPresentation } from "../toolRendering"
import explainStuckJobToolCard, { examples } from "./explain_stuck_job"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return { toolName: "explain_stuck_job", resultBody: "", resultError: false, parsedResult: null, ...overrides }
}

const LONG_REASON = `A **running Run** has a stale heartbeat. ${"Review its complete log before retrying. ".repeat(40)}`
const FULL_PAYLOAD = {
  job: {
    id: 5,
    slug: "JOB-5",
    state: "running",
    issue_title: "Fix the thing",
    branch_name: "syrus/fix-the-thing",
    pr_number: 17,
    pr_url: "https://github.com/acme/widget/pull/17",
    closure_reason: "waiting",
    landing_failure_reason: "checks failed"
  },
  stuck: true,
  issues: [
    {
      kind: "stale_heartbeat",
      severity: "high",
      attention_state: "auto_repairable",
      detail: "The **heartbeat** is stale.",
      workflow_id: 3,
      run_id: 9,
      repair_plan: { action: "mark_worker_died" }
    }
  ],
  stuck_list: { listed: true, items: [{ kind: "worker_missing", severity: "critical", detail: "No worker owns the Run.", workflow_id: 3, run_id: 9 }] },
  current_intent: { id: 22, kind: "initial", state: "waiting", wait_reason: "capacity", wait_until: "2026-10-24T00:00:00Z" },
  recommended_action: {
    action: "inspect_logs",
    reason: LONG_REASON,
    run_id: 9,
    pr_number: 17,
    work_unit_id: 31,
    next_check_at: "2026-10-23T12:00:00Z"
  },
  human_summary: "JOB-5 is **stuck** on its latest workflow.",
  workflows: {
    latest: { id: 3, state: "running", trigger_kind: "initial" },
    active: [{ id: 3, state: "running", trigger_kind: "initial" }],
    queued: [],
    failed: []
  },
  runs: {
    latest: { id: 9, workflow_id: 3, state: "running", step_kind: "implement" },
    active: [{ id: 9, workflow_id: 3, state: "running", step_kind: "implement" }],
    failed: []
  },
  dependencies: { pending: [], unsatisfied: [{ job_id: 4, slug: "JOB-4", state: "landing" }], multiple_leaf_dependencies: [] },
  landing: { mergeability: { github_state: "dirty", local_state: "conflicting" }, pr_checks: { state: "failing" }, commits_behind_base: 2 },
  work_units: {
    active: [{ id: 31, kind: "initial", state: "blocked", workflow_id: 3, blocked_reason: "no capable worker" }],
    recent: [{ id: 31, kind: "initial", state: "blocked" }]
  }
}

describe("explain_stuck_job tool card", () => {
  it("registers under the normalized MCP tool name and publishes catalog states", () => {
    expect(explainStuckJobToolCard.toolName).toBe("explain_stuck_job")
    expect(normalizedToolName("mcp__syrus-chat-sidecar__explain_stuck_job")).toBe("explain_stuck_job")
    expect(examples.map((example) => example.id)).toEqual(["stale_run_with_repair", "healthy_without_diagnostics", "authorization_error"])
  })

  it("renders real reasons, intent, metadata, linked entities, markdown, and wrapping", () => {
    render(<>{explainStuckJobToolCard.renderExpanded(context({ parsedResult: FULL_PAYLOAD }))}</>)

    expect(screen.getByRole("link", { name: /JOB-5/ })).toHaveAttribute("href", "/jobs/5")
    expect(screen.getByText("Fix the thing")).toBeInTheDocument()
    expect(screen.getByText("syrus/fix-the-thing")).toHaveClass("break-all", "min-w-0")
    expect(screen.getAllByRole("link", { name: "PR #17" })[0]).toHaveAttribute("href", "https://github.com/acme/widget/pull/17")
    expect(screen.getByText("stale heartbeat")).toBeInTheDocument()
    expect(screen.getByText("worker missing")).toBeInTheDocument()
    expect(screen.getByText("Intent 22")).toHaveAttribute("href", "/admin/work_units?job_id=5")
    expect(screen.getAllByText("WorkUnit 31")[0]).toHaveAttribute("href", "/admin/work_units?job_id=5")
    expect(screen.getAllByRole("link", { name: /WF-3/ })[0]).toHaveAttribute("href", "/jobs/5?tab=workflows#workflow-3")
    expect(screen.getAllByRole("link", { name: /RUN-9/ })[0]).toHaveAttribute("href", "/jobs/5?tab=workflows#workflow-3")
    expect(screen.getByRole("link", { name: /JOB-4/ })).toHaveAttribute("href", "/jobs/4")
    expect(screen.getByText("running Run").tagName).toBe("STRONG")
    expect(screen.getAllByRole("button", { name: "Show more" }).length).toBeGreaterThan(0)
    expect(screen.getByText(/GitHub: dirty/)).toBeInTheDocument()
  })

  it("resolves a run-only recommended action through the Runs payload", () => {
    render(<>{explainStuckJobToolCard.renderExpanded(context({ parsedResult: FULL_PAYLOAD }))}</>)

    const runLinks = screen.getAllByRole("link", { name: /RUN-9/ })
    expect(runLinks.length).toBeGreaterThan(1)
    expect(runLinks[0]).toHaveAttribute("href", "/jobs/5?tab=workflows#workflow-3")
  })

  it("falls back to an unlinked PR reference when no safe PR URL is available", () => {
    const parsedResult = { job: { id: 5, state: "running", pr_number: 17 }, stuck: false }
    render(<>{explainStuckJobToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("PR #17")).toBeInTheDocument()
    expect(screen.queryByRole("link", { name: "PR #17" })).not.toBeInTheDocument()
  })

  it("opens the complete markdown reason from Show more", () => {
    render(<>{explainStuckJobToolCard.renderExpanded(context({ parsedResult: FULL_PAYLOAD }))}</>)
    fireEvent.click(screen.getAllByRole("button", { name: "Show more" })[0])
    expect(screen.getByRole("dialog", { name: "Reason" })).toBeInTheDocument()
    expect(screen.getByRole("dialog")).toHaveTextContent("Review its complete log before retrying")
  })

  it.each([
    ["content text", { content: [{ type: "text", text: JSON.stringify(FULL_PAYLOAD) }], structured_content: null }, "JOB-5: stuck"],
    ["structured content", { content: [{ type: "text", text: "ignored" }], structured_content: FULL_PAYLOAD }, "JOB-5: stuck"]
  ])("normalizes the %s provider envelope", (_label, envelope, summary) => {
    expect(toolResultPresentation("mcp__provider__explain_stuck_job", JSON.stringify(envelope)).summary).toBe(summary)
  })

  it("renders explicit error and empty states", () => {
    const { rerender } = render(<>{explainStuckJobToolCard.renderExpanded(context({ resultError: true, parsedResult: { error: "not_authorized" } }))}</>)
    expect(screen.getByText("not_authorized")).toBeInTheDocument()
    expect(explainStuckJobToolCard.collapsedSummary?.(context({ resultError: true }))).toBe("Could not explain stuck Job")

    rerender(<>{explainStuckJobToolCard.renderExpanded(context({ resultSettled: true }))}</>)
    expect(screen.getByText("No diagnosis was returned.")).toBeInTheDocument()
  })

  it("renders a useful not-stuck state with missing optional diagnostics", () => {
    const parsedResult = { job: { id: 8, state: "implemented" }, stuck: false }
    render(<>{explainStuckJobToolCard.renderExpanded(context({ parsedResult }))}</>)
    expect(screen.getByText("not stuck")).toBeInTheDocument()
    expect(screen.getByText("No additional diagnostic details were returned.")).toBeInTheDocument()
    expect(explainStuckJobToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("JOB-8: not stuck")
  })

  it("returns null for malformed non-empty payloads so generic rendering remains available", () => {
    expect(explainStuckJobToolCard.renderExpanded(context({ parsedResult: { oops: true }, resultBody: '{"oops":true}', resultSettled: true }))).toBeNull()
  })
})
