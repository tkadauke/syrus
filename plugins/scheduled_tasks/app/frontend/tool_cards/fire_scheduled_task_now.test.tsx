import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import fireScheduledTaskNowToolCard from "./fire_scheduled_task_now"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "fire_scheduled_task_now",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

const pendingAction = {
  pending_confirmation_id: 501,
  pending_action_id: 501,
  state: "pending",
  message: "Fire scheduled task 12 immediately?"
}

describe("fire_scheduled_task_now tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(fireScheduledTaskNowToolCard.toolName).toBe("fire_scheduled_task_now")
  })

  it("summarizes the collapsed row with the pending action id and state", () => {
    expect(fireScheduledTaskNowToolCard.collapsedSummary?.(context({ parsedResult: pendingAction }))).toBe(
      "Fire now requested (#501, pending)"
    )
  })

  it("renders the state, message, and pending action id", () => {
    render(<>{fireScheduledTaskNowToolCard.renderExpanded(context({ parsedResult: pendingAction }))}</>)

    expect(screen.getByText("Immediate fire requested")).toBeInTheDocument()
    expect(screen.getByText("pending")).toBeInTheDocument()
    expect(screen.getByText("Fire scheduled task 12 immediately?")).toBeInTheDocument()
    expect(screen.getByText("#501")).toBeInTheDocument()
    expect(screen.getByText("The task does not fire until the operator confirms.")).toBeInTheDocument()
  })

  it("renders without confirm or reject controls", () => {
    render(<>{fireScheduledTaskNowToolCard.renderExpanded(context({ parsedResult: pendingAction }))}</>)

    expect(screen.queryAllByRole("button")).toHaveLength(0)
  })

  it("renders from pending_confirmation_id alone when pending_action_id is absent", () => {
    const parsedResult = { pending_confirmation_id: 777, state: "pending" }

    expect(fireScheduledTaskNowToolCard.collapsedSummary?.(context({ parsedResult }))).toBe(
      "Fire now requested (#777, pending)"
    )
  })

  it("falls back to null when the state is missing", () => {
    const parsedResult = { pending_action_id: 501 }

    expect(fireScheduledTaskNowToolCard.collapsedSummary?.(context({ parsedResult }))).toBeNull()
    expect(fireScheduledTaskNowToolCard.renderExpanded(context({ parsedResult }))).toBeNull()
  })

  it("falls back to null for a malformed payload", () => {
    const parsedResult = { oops: true }

    expect(fireScheduledTaskNowToolCard.collapsedSummary?.(context({ parsedResult }))).toBeNull()
    expect(fireScheduledTaskNowToolCard.renderExpanded(context({ parsedResult }))).toBeNull()
  })

  it("falls back to null for a non-object payload", () => {
    const parsedResult = "not json"

    expect(fireScheduledTaskNowToolCard.collapsedSummary?.(context({ parsedResult }))).toBeNull()
    expect(fireScheduledTaskNowToolCard.renderExpanded(context({ parsedResult }))).toBeNull()
  })
})
