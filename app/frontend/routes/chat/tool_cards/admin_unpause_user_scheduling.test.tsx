import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import { redactToolCardValue } from "@app/toolCardSecurity"
import { normalizedToolCardParsedResult, normalizedToolName } from "../toolRendering"
import adminUnpauseUserSchedulingToolCard from "./admin_unpause_user_scheduling"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  const parsedResult = overrides.parsedResult ?? {
    pending_action_id: 41,
    state: "pending",
    message: "Scheduling will resume for user #123."
  }

  return {
    toolName: "admin_unpause_user_scheduling",
    input: {
      user_id: 123,
      user_ids: [456, "operator-with-a-very-long-email-address@example.com"],
      reason: "Restore scheduling after **capacity recovered**."
    },
    resultBody: JSON.stringify(parsedResult),
    resultError: false,
    parsedResult,
    ...overrides
  }
}

function providerContext(rawName: string, envelope: unknown): ToolCardContext {
  return context({
    toolName: normalizedToolName(rawName),
    parsedResult: normalizedToolCardParsedResult(envelope),
    resultBody: JSON.stringify(envelope)
  })
}

describe("admin_unpause_user_scheduling tool card", () => {
  it("registers under the exact MCP tool name and renders every input and result field", () => {
    expect(adminUnpauseUserSchedulingToolCard.toolName).toBe("admin_unpause_user_scheduling")

    render(<>{adminUnpauseUserSchedulingToolCard.renderExpanded(context())}</>)

    expect(screen.getByText("pending")).toBeInTheDocument()
    expect(screen.getByText("Pending action #41")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "123" })).toHaveAttribute("href", "/admin/users/123")
    expect(screen.getByRole("link", { name: "456" })).toHaveAttribute("href", "/admin/users/456")
    expect(screen.getByRole("link", { name: "operator-with-a-very-long-email-address@example.com" })).toHaveAttribute(
      "href",
      "/admin/users/operator-with-a-very-long-email-address@example.com"
    )
    expect(screen.getByText("capacity recovered").tagName).toBe("STRONG")
    expect(screen.getByRole("link", { name: "user #123" })).toHaveAttribute("href", "/admin/users/123")
    expect(screen.getByRole("link", { name: "operator-with-a-very-long-email-address@example.com" })).toHaveClass("break-all")
  })

  it.each([
    ["pending", "pending"],
    ["confirmed", "confirmed"],
    ["rejected", "rejected"]
  ])("renders the %s state with group and member details", (state, expectedState) => {
    render(
      <>
        {adminUnpauseUserSchedulingToolCard.renderExpanded(
          context({
            parsedResult: {
              pending_action_id: 41,
              pending_action_group_id: 17,
              member_count: 2,
              state,
              message: "Scheduling update recorded.",
              reason: "Operator chose **this outcome**."
            }
          })
        )}
      </>
    )

    expect(screen.getByText(expectedState)).toBeInTheDocument()
    expect(screen.getByText("Pending action group #17")).toBeInTheDocument()
    expect(screen.getByText("2 actions")).toBeInTheDocument()
    expect(screen.getByText("Scheduling update recorded.")).toBeInTheDocument()
    expect(screen.getByText("this outcome").tagName).toBe("STRONG")
  })

  it("renders tool errors alongside the requested users and reason", () => {
    render(
      <>{adminUnpauseUserSchedulingToolCard.renderExpanded(context({ parsedResult: { error: "Unable to update **scheduling**." }, resultError: true }))}</>
    )

    expect(screen.getByText("failed")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "123" })).toHaveAttribute("href", "/admin/users/123")
    expect(screen.getByText("capacity recovered").tagName).toBe("STRONG")
    expect(screen.getByText("scheduling").tagName).toBe("STRONG")
  })

  it.each([
    ["structured_content", { structured_content: { pending_action_id: 41, state: "confirmed", message: "Scheduling resumed." } }],
    ["content text JSON", { content: [{ type: "text", text: JSON.stringify({ pending_action_id: 41, state: "confirmed", message: "Scheduling resumed." }) }] }]
  ])("normalizes the sidecar raw name and %s envelope", (_label, envelope) => {
    const toolContext = providerContext("mcp__syrus-chat-sidecar__admin_unpause_user_scheduling", envelope)

    expect(toolContext.toolName).toBe("admin_unpause_user_scheduling")
    expect(adminUnpauseUserSchedulingToolCard.collapsedSummary?.(toolContext)).toBe("Scheduling resumed.")
    render(<>{adminUnpauseUserSchedulingToolCard.renderExpanded(toolContext)}</>)
    expect(screen.getByText("confirmed")).toBeInTheDocument()
    expect(screen.getByText("Scheduling resumed.")).toBeInTheDocument()
  })

  it("renders only values retained by the shared redaction boundary", () => {
    const redactedInput = redactToolCardValue({
      user_id: 123,
      reason: "Resume for bearer super-secret-token after maintenance."
    }) as Record<string, unknown>

    render(<>{adminUnpauseUserSchedulingToolCard.renderExpanded(context({ input: redactedInput }))}</>)

    expect(screen.getByText(/\[redacted\]/)).toBeInTheDocument()
    expect(screen.queryByText(/super-secret-token/)).not.toBeInTheDocument()
  })
})
