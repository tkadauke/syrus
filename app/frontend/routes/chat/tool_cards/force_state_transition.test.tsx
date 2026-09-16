import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import forceStateTransitionToolCard from "./force_state_transition"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "force_state_transition",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

describe("force_state_transition tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(forceStateTransitionToolCard.toolName).toBe("force_state_transition")
  })

  it("summarizes the collapsed row via the shared pending-action message", () => {
    const context_ = context({
      input: { job_id: 4048, event: "cancel", reason: "Stuck for six hours." },
      parsedResult: { pending_confirmation_id: 501, pending_action_id: 501, state: "pending", reason: "Stuck for six hours.", message: "Apply cancel to JOB-4048?" }
    })
    expect(forceStateTransitionToolCard.collapsedSummary?.(context_)).toBe("Apply cancel to JOB-4048?")
  })

  it("renders the target job, requested event, outcome, and audit reason", () => {
    const context_ = context({
      input: { job_id: 4048, event: "cancel", reason: "Stuck for six hours." },
      parsedResult: { pending_confirmation_id: 501, pending_action_id: 501, state: "pending", reason: "Stuck for six hours.", message: "Apply cancel to JOB-4048?" }
    })
    render(<>{forceStateTransitionToolCard.renderExpanded(context_)}</>)

    expect(screen.getByText("JOB-4048")).toBeInTheDocument()
    expect(screen.getByText("cancel")).toBeInTheDocument()
    expect(screen.getByText("pending")).toBeInTheDocument()
    expect(screen.getByText("Reason")).toBeInTheDocument()
    expect(screen.getByText("Stuck for six hours.")).toBeInTheDocument()
    expect(screen.getByText("Apply cancel to JOB-4048?")).toBeInTheDocument()
  })

  it("omits the job/event header row when the tool call carried no input", () => {
    render(<>{forceStateTransitionToolCard.renderExpanded(context({ parsedResult: { pending_action_id: 501, state: "pending" } }))}</>)

    expect(screen.getByText("pending")).toBeInTheDocument()
    expect(screen.queryByText(/JOB-/)).not.toBeInTheDocument()
  })

  it("falls back to null for a malformed or error payload", () => {
    expect(forceStateTransitionToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(forceStateTransitionToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
    expect(forceStateTransitionToolCard.renderExpanded(context({ resultError: true, parsedResult: null, resultBody: "Error: job not found: 9999" }))).toBeNull()
  })
})
