import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import emergencyLandToolCard from "./emergency_land"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "emergency_land",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

describe("emergency_land tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(emergencyLandToolCard.toolName).toBe("emergency_land")
  })

  it("summarizes the collapsed row via the shared pending-action message", () => {
    const context_ = context({
      input: { job_id: 4242, branch_name: "syrus/incident-fix" },
      parsedResult: { pending_confirmation_id: 701, pending_action_id: 701, state: "pending", message: "Emergency land requires operator confirmation." }
    })

    expect(emergencyLandToolCard.collapsedSummary?.(context_)).toBe("Emergency land requires operator confirmation.")
  })

  it("renders the target job, branch, and pending confirmation state", () => {
    const context_ = context({
      input: { job_id: 4242, branch_name: "syrus/incident-fix" },
      parsedResult: { pending_confirmation_id: 701, pending_action_id: 701, state: "pending", message: "Emergency land requires operator confirmation." }
    })

    render(<>{emergencyLandToolCard.renderExpanded(context_)}</>)

    expect(screen.getByText("JOB-4242")).toBeInTheDocument()
    expect(screen.getByText("syrus/incident-fix")).toBeInTheDocument()
    expect(screen.getByText("pending")).toBeInTheDocument()
    expect(screen.getByText("Emergency land requires operator confirmation.")).toBeInTheDocument()
  })

  it("falls back to null for malformed payloads", () => {
    expect(emergencyLandToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(emergencyLandToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
