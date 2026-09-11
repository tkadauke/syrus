import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import listRefMovementActionsToolCard from "./list_ref_movement_actions"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return { toolName: "list_ref_movement_actions", resultBody: "", resultError: false, parsedResult: null, ...overrides }
}

describe("list_ref_movement_actions tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(listRefMovementActionsToolCard.toolName).toBe("list_ref_movement_actions")
  })

  it("summarizes availability as available/total", () => {
    const parsedResult = {
      repository: "tkadauke/syrus",
      ref_movement_actions: [
        { name: "send_job_upstream", enabled: true, mode: "auto", grade_phases: [], available: true, blocked_reason: null },
        {
          name: "submit_branch_upstream",
          enabled: false,
          mode: null,
          grade_phases: [],
          available: false,
          blocked_reason: "not enabled in delivery.ref_movement_actions"
        }
      ]
    }
    expect(listRefMovementActionsToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("1/2 ref movement actions available")
  })

  it("renders an empty state when none are configured", () => {
    render(<>{listRefMovementActionsToolCard.renderExpanded(context({ parsedResult: { repository: "tkadauke/syrus", ref_movement_actions: [] } }))}</>)
    expect(screen.getByText("No ref movement actions configured.")).toBeInTheDocument()
  })

  it("renders a blocked reason for an unavailable action", () => {
    const parsedResult = {
      repository: "tkadauke/syrus",
      ref_movement_actions: [
        { name: "send_job_upstream", enabled: true, mode: "auto", grade_phases: [], available: false, blocked_reason: "job_id is required" }
      ]
    }

    render(<>{listRefMovementActionsToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("send_job_upstream")).toBeInTheDocument()
    expect(screen.getByText("job_id is required")).toBeInTheDocument()
  })

  it("falls back to null for a malformed payload", () => {
    expect(listRefMovementActionsToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(listRefMovementActionsToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
