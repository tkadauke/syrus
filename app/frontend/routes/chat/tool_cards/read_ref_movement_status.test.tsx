import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import readRefMovementStatusToolCard from "./read_ref_movement_status"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return { toolName: "read_ref_movement_status", resultBody: "", resultError: false, parsedResult: null, ...overrides }
}

describe("read_ref_movement_status tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(readRefMovementStatusToolCard.toolName).toBe("read_ref_movement_status")
  })

  it("summarizes the action state", () => {
    const parsedResult = { ref_movement_action_id: 7, action_name: "send_job_upstream", state: "dispatched" }
    expect(readRefMovementStatusToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("send job upstream (dispatched)")
  })

  it("renders job, workflow, and pr_link summaries when present", () => {
    const parsedResult = {
      ref_movement_action_id: 7,
      action_name: "send_job_upstream",
      state: "dispatched",
      job: { id: 4225, slug: "JOB-325", state: "landing" },
      workflow: { id: 900, state: "running", trigger_kind: "upstream_export" },
      pr_link: { pr_number: 12, target_repository: "upstream/syrus", target_ref: "main" }
    }

    render(<>{readRefMovementStatusToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("JOB-325")).toBeInTheDocument()
    expect(screen.getByText("landing")).toBeInTheDocument()
    expect(screen.getByText("WORKFLOW-900")).toBeInTheDocument()
    expect(screen.getByText("upstream_export")).toBeInTheDocument()
    expect(screen.getByText("#12")).toBeInTheDocument()
    expect(screen.getByText("upstream/syrus")).toBeInTheDocument()
  })

  it("omits job/workflow/pr_link sections when absent", () => {
    const parsedResult = { ref_movement_action_id: 7, action_name: "submit_branch_upstream", state: "dispatched" }
    render(<>{readRefMovementStatusToolCard.renderExpanded(context({ parsedResult }))}</>)
    expect(screen.queryByText("Job")).not.toBeInTheDocument()
    expect(screen.queryByText("Workflow")).not.toBeInTheDocument()
  })

  it("falls back to null for a malformed payload", () => {
    expect(readRefMovementStatusToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(readRefMovementStatusToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
