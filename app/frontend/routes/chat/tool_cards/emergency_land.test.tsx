import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import { toolCardContextForExample, type ToolCardContext } from "@app/pluginToolCards"
import { normalizedToolCardParsedResult, normalizedToolName, toolResultPresentation } from "../toolRendering"
import emergencyLandToolCard, { examples } from "./emergency_land"

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
    expect(normalizedToolName("mcp__syrus-chat-sidecar__emergency_land")).toBe("emergency_land")
  })

  it("summarizes the collapsed row via the shared pending-action message", () => {
    const context_ = context({
      input: { job_id: 4242, branch_name: "syrus/incident-fix" },
      parsedResult: { pending_confirmation_id: 701, pending_action_id: 701, state: "pending", message: "Emergency land requires operator confirmation." }
    })

    expect(emergencyLandToolCard.collapsedSummary?.(context_)).toBe("Emergency land requires operator confirmation.")
  })

  it("renders linked target context, Markdown details, and a prominent destructive warning", () => {
    const context_ = context({
      input: { job_id: 4242, branch_name: "syrus/incident-fix" },
      parsedResult: {
        pending_confirmation_id: 701,
        pending_action_id: 701,
        state: "pending",
        message: "Emergency land requires **operator confirmation**.",
        reason: "Requested for **incident recovery**."
      }
    })

    render(<>{emergencyLandToolCard.renderExpanded(context_)}</>)

    expect(screen.getByRole("link", { name: "JOB-4242" })).toHaveAttribute("href", "/jobs/4242")
    expect(screen.getByText("syrus/incident-fix")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Copy syrus/incident-fix to clipboard" })).toBeInTheDocument()
    expect(screen.getByText("pending")).toBeInTheDocument()
    expect(screen.getByText("operator confirmation").tagName).toBe("STRONG")
    expect(screen.getByText("incident recovery").tagName).toBe("STRONG")
    expect(screen.getByRole("alert")).toHaveTextContent("Destructive emergency action")
    expect(screen.getByRole("alert")).toHaveTextContent("skips graders, adversarial review, and visual review")
  })

  it.each([
    "Emergency land is not enabled on this instance.",
    "emergency_land requires a Coding Mode chat.",
    "Repository admin permissions are required for emergency land."
  ])("renders a plain-text tool error with target context: %s", (message) => {
    const errorContext = context({ input: { job_id: 4242, branch_name: "syrus/incident-fix" }, resultBody: message, resultError: true })

    expect(emergencyLandToolCard.collapsedSummary?.(errorContext)).toBe(message)
    render(<>{emergencyLandToolCard.renderExpanded(errorContext)}</>)
    expect(screen.getByText("failed")).toBeInTheDocument()
    expect(screen.getByText(message)).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "JOB-4242" })).toHaveAttribute("href", "/jobs/4242")
    expect(screen.getByRole("alert")).toBeInTheDocument()
  })

  it("accepts provider-normalized envelopes and an mcp-prefixed tool name", () => {
    const payload = {
      pending_action_id: 701,
      state: "pending",
      message: "Emergency land requires **operator confirmation**."
    }
    const envelopes = [
      { content: [{ type: "text", text: JSON.stringify(payload) }] },
      { content: [{ type: "text", text: "ignored" }], structured_content: payload }
    ]

    for (const envelope of envelopes) {
      const { unmount } = render(
        <>{emergencyLandToolCard.renderExpanded(context({ input: { job_id: 4242 }, parsedResult: normalizedToolCardParsedResult(envelope) }))}</>
      )
      expect(screen.getByText("operator confirmation").tagName).toBe("STRONG")
      unmount()
    }

    const body = JSON.stringify(envelopes[0])
    expect(toolResultPresentation("mcp__syrus-chat-sidecar__emergency_land", body).summary).toBe("Emergency land requires operator confirmation.")
  })

  it("keeps its catalog examples renderable", () => {
    expect(examples.map((example) => example.id)).toEqual(["pending_confirmation", "feature_disabled"])
    for (const example of examples) {
      const view = render(<>{emergencyLandToolCard.renderExpanded(toolCardContextForExample(emergencyLandToolCard.toolName, example))}</>)
      expect(view.container).not.toBeEmptyDOMElement()
      view.unmount()
    }
  })

  it("falls back to null for malformed non-error payloads", () => {
    expect(emergencyLandToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(emergencyLandToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
