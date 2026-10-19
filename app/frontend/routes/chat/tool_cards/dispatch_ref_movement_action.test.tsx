import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import { normalizedToolCardParsedResult, normalizedToolName } from "../toolRendering"
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
    expect(screen.getByRole("link", { name: /JOB-4225/ })).toHaveAttribute("href", "/jobs/4225")
    expect(screen.getByRole("link", { name: /WF-900/ })).toHaveAttribute("href", "/jobs/4225?tab=workflows#workflow-900")
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

  it("renders input and an error state when the result has no payload", () => {
    const errorContext = context({
      input: { action: "submit_branch_upstream", source_branch: "release/source", target_branch: "main" },
      resultBody: "Dispatcher **temporarily unavailable**",
      resultError: true
    })

    expect(dispatchRefMovementActionToolCard.collapsedSummary?.(errorContext)).toBe("submit branch upstream failed")
    render(<>{dispatchRefMovementActionToolCard.renderExpanded(errorContext)}</>)
    expect(screen.getByText("failed")).toBeInTheDocument()
    expect(screen.getByText("temporarily unavailable").tagName).toBe("STRONG")
    expect(screen.getByText("release/source")).toBeInTheDocument()
    expect(screen.getByText("main")).toBeInTheDocument()
  })

  it("accepts MCP text and structured-content envelopes after provider normalization", () => {
    const payload = { ref_movement_action_id: 12, action_name: "send_job_upstream", state: "pending" }
    const textEnvelope = { content: [{ type: "text", text: JSON.stringify(payload) }] }
    const structuredEnvelope = { structured_content: payload, content: [{ type: "text", text: "ignored" }] }

    expect(dispatchRefMovementActionToolCard.collapsedSummary?.(context({ parsedResult: normalizedToolCardParsedResult(textEnvelope) }))).toBe(
      "send job upstream (pending)"
    )
    expect(dispatchRefMovementActionToolCard.collapsedSummary?.(context({ parsedResult: normalizedToolCardParsedResult(structuredEnvelope) }))).toBe(
      "send job upstream (pending)"
    )
    expect(normalizedToolName("mcp__syrus-chat-sidecar__dispatch_ref_movement_action")).toBe("dispatch_ref_movement_action")
  })

  it("links the target repository and shows partial pending results", () => {
    const parsedResult = { state: "pending", target_repository: "upstream/syrus" }
    render(<>{dispatchRefMovementActionToolCard.renderExpanded(context({ input: { action: "send_job_upstream" }, parsedResult }))}</>)

    expect(screen.getByText("pending")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: /upstream\/syrus/ })).toHaveAttribute("href", "https://github.com/upstream/syrus")
  })
})
