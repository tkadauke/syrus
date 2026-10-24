import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import { normalizedToolCardParsedResult, normalizedToolName } from "../toolRendering"
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
      requested_by: "operator@example.com",
      job: { id: 4225, slug: "JOB-325", state: "landing" },
      workflow: { id: 900, state: "running", trigger_kind: "upstream_export" },
      pr_link: { pr_number: 12, pr_state: "open", source_ref: "syrus/direct-325", target_repository: "upstream/syrus", target_ref: "main" }
    }

    render(<>{readRefMovementStatusToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByRole("link", { name: /JOB-325/ })).toHaveAttribute("href", "/jobs/4225")
    expect(screen.getByText("landing")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: /WF-900/ })).toHaveAttribute("href", "/jobs/4225?tab=workflows#workflow-900")
    expect(screen.getByText("upstream_export")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: /PR #12/ })).toHaveAttribute("href", "https://github.com/upstream/syrus/pull/12")
    expect(screen.getByRole("link", { name: /upstream\/syrus/ })).toHaveAttribute("href", "https://github.com/upstream/syrus")
    expect(screen.getByText("operator@example.com")).toBeInTheDocument()
    expect(screen.getByText("open")).toBeInTheDocument()
    expect(screen.getByText("syrus/direct-325")).toBeInTheDocument()
    expect(screen.getByText("7")).toBeInTheDocument()
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

  it("renders partial jobs without requiring a slug or state", () => {
    const parsedResult = { ref_movement_action_id: 8, state: "pending", job: { id: 4225 } }
    render(<>{readRefMovementStatusToolCard.renderExpanded(context({ parsedResult }))}</>)
    expect(screen.getByRole("link", { name: /JOB-4225/ })).toHaveAttribute("href", "/jobs/4225")
  })

  it("accepts MCP text and structured-content envelopes after provider normalization", () => {
    const payload = { ref_movement_action_id: 12, action_name: "send_job_upstream", state: "pending" }
    const textEnvelope = { content: [{ type: "text", text: JSON.stringify(payload) }] }
    const structuredEnvelope = { structured_content: payload, content: [{ type: "text", text: "ignored" }] }

    expect(readRefMovementStatusToolCard.collapsedSummary?.(context({ parsedResult: normalizedToolCardParsedResult(textEnvelope) }))).toBe(
      "send job upstream (pending)"
    )
    expect(readRefMovementStatusToolCard.collapsedSummary?.(context({ parsedResult: normalizedToolCardParsedResult(structuredEnvelope) }))).toBe(
      "send job upstream (pending)"
    )
    expect(normalizedToolName("mcp__syrus-chat-sidecar__read_ref_movement_status")).toBe("read_ref_movement_status")
  })

  it("renders the requested action and error details when status lookup fails", () => {
    const failure = context({ input: { ref_movement_action_id: 77 }, resultBody: "Action **not found**", resultError: true })
    expect(readRefMovementStatusToolCard.collapsedSummary?.(failure)).toBe("Ref movement 77 failed")
    render(<>{readRefMovementStatusToolCard.renderExpanded(failure)}</>)
    expect(screen.getByText("Ref movement 77")).toBeInTheDocument()
    expect(screen.getByText("failed")).toBeInTheDocument()
    expect(screen.getByText("not found").tagName).toBe("STRONG")
  })
})
