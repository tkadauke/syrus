import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import { toolCardContextForExample, type ToolCardContext } from "@app/pluginToolCards"
import { normalizedToolCardParsedResult } from "@app/toolCardParsing"
import { normalizedToolName } from "../toolRendering"
import forceStateTransitionToolCard, { examples } from "./force_state_transition"

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
  it("registers visual catalog examples for pending, confirmed, and error states", () => {
    expect(examples.map((example) => example.id)).toEqual(["pending_confirmation", "confirmed_transition", "tool_error"])

    for (const example of examples) {
      const exampleContext = toolCardContextForExample(forceStateTransitionToolCard.toolName, example)
      expect(forceStateTransitionToolCard.renderExpanded(exampleContext), example.id).not.toBeNull()
    }

    const pendingContext = toolCardContextForExample(forceStateTransitionToolCard.toolName, examples[0])
    render(<>{forceStateTransitionToolCard.renderExpanded(pendingContext)}</>)
    expect(screen.getAllByRole("button", { name: "Show more" })).toHaveLength(2)
  })

  it("registers under the exact MCP tool name", () => {
    expect(forceStateTransitionToolCard.toolName).toBe("force_state_transition")
    expect(normalizedToolName("mcp__syrus-chat-sidecar__force_state_transition")).toBe(forceStateTransitionToolCard.toolName)
  })

  it("summarizes the collapsed row via the shared pending-action message", () => {
    const context_ = context({
      input: { job_id: 4048, event: "cancel", reason: "Stuck for six hours." },
      parsedResult: {
        pending_confirmation_id: 501,
        pending_action_id: 501,
        state: "pending",
        reason: "Stuck for six hours.",
        message: "Apply cancel to JOB-4048?"
      }
    })
    expect(forceStateTransitionToolCard.collapsedSummary?.(context_)).toBe("Apply cancel to JOB-4048?")
  })

  it.each([
    ["text content", (payload: unknown) => ({ content: [{ type: "text", text: JSON.stringify(payload) }], structured_content: null })],
    ["structured content", (payload: unknown) => ({ content: [], structured_content: payload })]
  ])("renders linked context and expandable Markdown from a normalizer-built %s envelope", (_label, envelope) => {
    const reason = `**Audit reason:** ${"State ownership was verified before applying the repair. ".repeat(20)}`
    const message = `Apply **force fail** to JOB-4048? ${"This action is operator-confirmed. ".repeat(20)}`
    const payload = { pending_confirmation_id: 501, pending_action_id: 501, state: "pending", reason, message }
    const context_ = context({
      toolName: normalizedToolName("mcp__syrus-chat-sidecar__force_state_transition"),
      input: { job_id: 4048, event: "force_fail", reason },
      parsedResult: normalizedToolCardParsedResult(envelope(payload))
    })
    render(<>{forceStateTransitionToolCard.renderExpanded(context_)}</>)

    expect(screen.getByRole("link", { name: "JOB-4048" })).toHaveAttribute("href", "/jobs/4048")
    expect(screen.getByRole("button", { name: "Copy JOB-4048 to clipboard" })).toBeInTheDocument()
    expect(screen.getAllByText("force_fail").length).toBeGreaterThan(0)
    expect(screen.getByText("pending")).toBeInTheDocument()
    expect(screen.getByText("Audit reason:", { selector: "strong" })).toBeInTheDocument()
    expect(screen.getByText("force fail", { selector: "strong" })).toBeInTheDocument()
    expect(screen.getAllByRole("button", { name: "Show more" })).toHaveLength(2)
  })

  it("shows the live Job state transition after the pending action executes", () => {
    const context_ = context({
      input: { job_id: 4048, event: "force_fail", reason: "Repair state drift." },
      parsedResult: { pending_action_id: 501, state: "pending", message: "Apply force_fail to JOB-4048?" },
      livePendingAction: {
        id: 501,
        action: "force_state_transition",
        state: "confirmed",
        label: "Force force_fail on JOB-4048",
        detail: "Event: force_fail",
        before_snapshot: { jobs: [{ id: 4048, state: "implemented" }] },
        after_snapshot: { jobs: [{ id: 4048, state: "failed" }] },
        app_confirm_path: "/confirm",
        app_reject_path: "/reject"
      }
    })
    render(<>{forceStateTransitionToolCard.renderExpanded(context_)}</>)

    expect(screen.getByText("Transition")).toBeInTheDocument()
    expect(screen.getByText("implemented")).toBeInTheDocument()
    expect(screen.getByText("failed")).toBeInTheDocument()
  })

  it("omits the job/event header row when the tool call carried no input", () => {
    render(<>{forceStateTransitionToolCard.renderExpanded(context({ parsedResult: { pending_action_id: 501, state: "pending" } }))}</>)

    expect(screen.getByText("pending")).toBeInTheDocument()
    expect(screen.queryByText(/JOB-/)).not.toBeInTheDocument()
  })

  it("falls back to null for a malformed payload and renders a useful error state", () => {
    expect(forceStateTransitionToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(forceStateTransitionToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
    render(
      <>
        {forceStateTransitionToolCard.renderExpanded(
          context({
            input: { job_id: 9999, event: "force_fail", reason: "Repair drift." },
            resultError: true,
            parsedResult: null,
            resultBody: "Error: job not found: 9999"
          })
        )}
      </>
    )
    expect(screen.getByText("failed")).toBeInTheDocument()
    expect(screen.getByText("Error: job not found: 9999")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "JOB-9999" })).toHaveAttribute("href", "/jobs/9999")
  })
})
