import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import completeImplementStepToolCard from "./complete_implement_step"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "complete_implement_step",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

describe("complete_implement_step tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(completeImplementStepToolCard.toolName).toBe("complete_implement_step")
  })

  it("summarizes the collapsed row via the shared pending-action message", () => {
    const context_ = context({
      input: { job_id: 4048, branch_name: "syrus/coding-322" },
      parsedResult: { pending_confirmation_id: 501, pending_action_id: 501, state: "pending", message: "Implementation handoff requires operator confirmation." }
    })
    expect(completeImplementStepToolCard.collapsedSummary?.(context_)).toBe("Implementation handoff requires operator confirmation.")
  })

  it("renders the target job, pushed branch, and pending confirmation state", () => {
    const context_ = context({
      input: { job_id: 4048, branch_name: "syrus/coding-322" },
      parsedResult: { pending_confirmation_id: 501, pending_action_id: 501, state: "pending", message: "Implementation handoff requires operator confirmation." }
    })
    render(<>{completeImplementStepToolCard.renderExpanded(context_)}</>)

    expect(screen.getByText("JOB-4048")).toBeInTheDocument()
    expect(screen.getByText("syrus/coding-322")).toBeInTheDocument()
    expect(screen.getByText("pending")).toBeInTheDocument()
    expect(screen.getByText("Implementation handoff requires operator confirmation.")).toBeInTheDocument()
  })

  it("renders a rejected outcome using whatever state the payload carries", () => {
    const context_ = context({
      input: { job_id: 4048 },
      parsedResult: { pending_action_id: 501, state: "rejected", message: "Implementation handoff requires operator confirmation." }
    })
    render(<>{completeImplementStepToolCard.renderExpanded(context_)}</>)

    expect(screen.getByText("rejected")).toBeInTheDocument()
    expect(screen.getByText("JOB-4048")).toBeInTheDocument()
  })

  it("omits the job/branch header row when the tool call carried no input", () => {
    render(<>{completeImplementStepToolCard.renderExpanded(context({ parsedResult: { pending_action_id: 501, state: "pending" } }))}</>)

    expect(screen.getByText("pending")).toBeInTheDocument()
    expect(screen.queryByText(/JOB-/)).not.toBeInTheDocument()
  })

  it("falls back to null for a malformed or error payload", () => {
    expect(completeImplementStepToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(completeImplementStepToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
    expect(completeImplementStepToolCard.renderExpanded(context({ resultError: true, parsedResult: null, resultBody: "Error: job_id is required" }))).toBeNull()
  })
})
