import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ChatPendingActionInline } from "@app/api/chats"
import type { ToolCardContext } from "@app/pluginToolCards"
import { redactToolCardValue } from "@app/toolCardSecurity"
import { normalizedToolCardParsedResult, normalizedToolName } from "../toolRendering"
import adminRetryStepToolCard from "./admin_retry_step"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "admin_retry_step",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

const INPUT = {
  workflow_id: 612,
  workflow_ids: [613, 614],
  step_slug: "implementation-step-with-a-very-long-slug-that-must-wrap-on-mobile",
  reason: "Retry after **reviewing the failure** in JOB-7551."
}

const PENDING_RESULT = {
  pending_action_group_id: 91,
  pending_action_id: 507,
  pending_confirmation_id: 507,
  state: "pending",
  member_count: 3,
  message: "Retry implementation-step for workflow #612 and workflow #613?",
  reason: "The previous attempt failed after **dependency preparation**."
}

function redactedContext(overrides: Partial<ToolCardContext> = {}) {
  const redacted = redactToolCardValue({ input: INPUT, parsedResult: PENDING_RESULT, ...overrides }) as {
    input: Record<string, unknown>
    parsedResult: unknown
  }

  return context({ ...overrides, input: redacted.input, parsedResult: redacted.parsedResult })
}

describe("admin_retry_step tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(adminRetryStepToolCard.toolName).toBe("admin_retry_step")
    expect(normalizedToolName("mcp__syrus-chat-sidecar__admin_retry_step")).toBe("admin_retry_step")
  })

  it("renders every target and parameter with linked workflows, a step badge, Markdown, and grouped result details", () => {
    const { container } = render(<>{adminRetryStepToolCard.renderExpanded(redactedContext())}</>)

    expect(screen.getByRole("link", { name: "WF-612" })).toHaveAttribute("href", "/admin/workflows/612")
    expect(screen.getByRole("link", { name: "WF-613" })).toHaveAttribute("href", "/admin/workflows/613")
    expect(screen.getByRole("link", { name: "WF-614" })).toHaveAttribute("href", "/admin/workflows/614")
    expect(screen.getByText(INPUT.step_slug)).toBeInTheDocument()
    expect(screen.getByText("reviewing the failure").tagName).toBe("STRONG")

    expect(screen.getByText("pending")).toBeInTheDocument()
    expect(screen.getByText("Pending action group #91")).toBeInTheDocument()
    expect(screen.getByText("3 actions")).toBeInTheDocument()
    expect(screen.getByText("dependency preparation").tagName).toBe("STRONG")
    expect(screen.getByRole("link", { name: "workflow #612" })).toHaveAttribute("href", "/admin/workflows/612")
    expect(screen.getByRole("link", { name: "workflow #613" })).toHaveAttribute("href", "/admin/workflows/613")

    expect(container.firstElementChild).toHaveClass("min-w-0")
    expect(screen.getByRole("link", { name: "WF-612" })).toHaveClass("break-all")
  })

  it.each([
    ["pending", null],
    ["confirmed", null],
    ["rejected", "Superseded by a newer workflow retry."]
  ])("renders the %s action state", (state, reason) => {
    const livePendingAction: ChatPendingActionInline = {
      id: 507,
      action: "admin_retry_step",
      state: state as ChatPendingActionInline["state"],
      label: "Retry step",
      detail: null,
      reason,
      app_confirm_path: "/pending_actions/507/confirm",
      app_reject_path: "/pending_actions/507/reject"
    }

    render(<>{adminRetryStepToolCard.renderExpanded(redactedContext({ livePendingAction }))}</>)

    expect(screen.getByText(state)).toBeInTheDocument()
    expect(screen.getByText(INPUT.step_slug)).toBeInTheDocument()
    if (reason) expect(screen.getByText(reason)).toBeInTheDocument()
  })

  it("renders tool errors alongside redacted retry inputs", () => {
    const secret = "sk-abcdefghijklmnopqrstuvwxyz123456"
    const redacted = redactToolCardValue({
      input: { ...INPUT, reason: `Retry with token=${secret}` },
      parsedResult: { error: `Retry service refused token=${secret}` }
    }) as { input: Record<string, unknown>; parsedResult: unknown }

    render(
      <>
        {adminRetryStepToolCard.renderExpanded(
          context({ input: redacted.input, parsedResult: redacted.parsedResult, resultBody: JSON.stringify(redacted.parsedResult), resultError: true })
        )}
      </>
    )

    expect(screen.getByText("failed")).toBeInTheDocument()
    expect(screen.getByText(/Retry service refused token=\[redacted\]/)).toBeInTheDocument()
    expect(screen.getByText(/Retry with token=\[redacted\]/)).toBeInTheDocument()
    expect(screen.queryByText(secret)).not.toBeInTheDocument()
  })

  it.each([
    ["structured_content", { structured_content: PENDING_RESULT }],
    ["content text JSON", { content: [{ type: "text", text: JSON.stringify(PENDING_RESULT) }], structured_content: null }]
  ])("renders the shared normalized %s envelope", (_label, envelope) => {
    const parsedResult = redactToolCardValue(normalizedToolCardParsedResult(envelope))
    const view = render(<>{adminRetryStepToolCard.renderExpanded(context({ input: INPUT, parsedResult }))}</>)

    expect(screen.getByText("Pending action group #91")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "WF-612" })).toHaveAttribute("href", "/admin/workflows/612")
    view.unmount()
  })

  it("falls back for malformed results", () => {
    expect(adminRetryStepToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(adminRetryStepToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
