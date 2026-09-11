import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import dispatchRefMovementActionToolCard from "./dispatch_ref_movement_action"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return { toolName: "dispatch_ref_movement_action", resultBody: "", resultError: false, parsedResult: null, ...overrides }
}

describe("dispatch_ref_movement_action tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(dispatchRefMovementActionToolCard.toolName).toBe("dispatch_ref_movement_action")
  })

  it("summarizes a dispatched action and renders the job/workflow links", () => {
    const parsedResult = {
      ref_movement_action_id: 7,
      action_name: "send_job_upstream",
      state: "dispatched",
      source_kind: "job",
      source_ref: "syrus/direct-325",
      target_kind: "branch",
      target_ref: "main",
      job_id: 4225,
      workflow_id: 900
    }

    expect(dispatchRefMovementActionToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("send job upstream (dispatched)")

    render(<>{dispatchRefMovementActionToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("JOB-4225")).toBeInTheDocument()
    expect(screen.getByText("WORKFLOW-900")).toBeInTheDocument()
  })

  it("still renders a blocked dispatch (the audit record is always created)", () => {
    const parsedResult = {
      ref_movement_action_id: 8,
      action_name: "send_job_upstream",
      state: "blocked",
      blocked_reason: "job_id is required for send_job_upstream"
    }

    expect(dispatchRefMovementActionToolCard.collapsedSummary?.(context({ parsedResult }))).toBe(
      "send job upstream blocked: job_id is required for send_job_upstream"
    )

    render(<>{dispatchRefMovementActionToolCard.renderExpanded(context({ parsedResult }))}</>)
    expect(screen.getByText("job_id is required for send_job_upstream")).toBeInTheDocument()
  })

  it("falls back to null for a malformed payload", () => {
    expect(dispatchRefMovementActionToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(dispatchRefMovementActionToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
