import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import { normalizedToolCardParsedResult, normalizedToolName, toolLabel, toolResultPresentation } from "../toolRendering"
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
      parsedResult: {
        pending_confirmation_id: 501,
        pending_action_id: 501,
        state: "pending",
        message: "Implementation handoff requires operator confirmation."
      }
    })
    expect(completeImplementStepToolCard.collapsedSummary?.(context_)).toBe("Implementation handoff requires operator confirmation.")
  })

  it("renders the target job, pushed branch, and pending confirmation state", () => {
    const context_ = context({
      input: { job_id: 4048, branch_name: "syrus/coding-322" },
      parsedResult: {
        pending_confirmation_id: 501,
        pending_action_id: 501,
        state: "pending",
        message: "Implementation handoff requires operator confirmation."
      }
    })
    render(<>{completeImplementStepToolCard.renderExpanded(context_)}</>)

    expect(screen.getByRole("link", { name: "JOB-4048" })).toHaveAttribute("href", "/jobs/4048")
    expect(screen.getByText("syrus/coding-322")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Copy syrus/coding-322 to clipboard" })).toBeInTheDocument()
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
    expect(screen.getByText("Active checkout branch")).toBeInTheDocument()
  })

  it("omits the job/branch header row when the tool call carried no input", () => {
    render(<>{completeImplementStepToolCard.renderExpanded(context({ parsedResult: { pending_action_id: 501, state: "pending" } }))}</>)

    expect(screen.getByText("pending")).toBeInTheDocument()
    expect(screen.queryByText(/JOB-/)).not.toBeInTheDocument()
  })

  it("falls back to null for a malformed payload and renders plain-text errors", () => {
    expect(completeImplementStepToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(completeImplementStepToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
    const errorContext = context({ input: { job_id: 4048 }, resultError: true, parsedResult: null, resultBody: "Error: job_id is required" })
    expect(completeImplementStepToolCard.collapsedSummary?.(errorContext)).toContain("is required")
    render(<>{completeImplementStepToolCard.renderExpanded(errorContext)}</>)
    expect(screen.getByText("failed")).toBeInTheDocument()
    expect(screen.getByText("Error: job_id is required")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "JOB-4048" })).toHaveAttribute("href", "/jobs/4048")
  })

  it("accepts provider result envelopes and renders Markdown messages", () => {
    const payload = {
      pending_action_id: 501,
      state: "pending",
      message: "Review the **implementation handoff** before confirming."
    }

    for (const envelope of [
      { content: [{ type: "text", text: JSON.stringify(payload) }] },
      { content: [{ type: "text", text: "ignored" }], structured_content: payload }
    ]) {
      const { unmount } = render(
        <>{completeImplementStepToolCard.renderExpanded(context({ input: { job_id: 4048 }, parsedResult: normalizedToolCardParsedResult(envelope) }))}</>
      )
      expect(screen.getByText("implementation handoff").tagName).toBe("STRONG")
      unmount()
    }
  })

  it("is discovered through an mcp-prefixed tool name", () => {
    const body = JSON.stringify({
      content: [{ type: "text", text: JSON.stringify({ pending_action_id: 501, state: "pending", message: "Ready for confirmation." }) }]
    })

    expect(normalizedToolName("mcp__syrus-chat-sidecar__complete_implement_step")).toBe(completeImplementStepToolCard.toolName)
    expect(toolLabel("mcp__syrus-chat-sidecar__complete_implement_step")).toBe("Complete implement step")
    expect(toolResultPresentation("mcp__syrus-chat-sidecar__complete_implement_step", body)).toMatchObject({ summary: "Ready for confirmation." })
  })
})
