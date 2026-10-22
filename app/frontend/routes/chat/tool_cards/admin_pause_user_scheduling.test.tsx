import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import { redactToolCardValue } from "@app/toolCardSecurity"
import { normalizedToolCardParsedResult, normalizedToolName, toolResultPresentation } from "../toolRendering"
import adminPauseUserSchedulingToolCard from "./admin_pause_user_scheduling"

function context(parsedResult: unknown, overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "admin_pause_user_scheduling",
    resultBody: "",
    resultError: false,
    ...overrides,
    parsedResult: redactToolCardValue(parsedResult),
    input: redactToolCardValue(overrides.input || {}) as Record<string, unknown>,
    livePendingAction: redactToolCardValue(overrides.livePendingAction ?? null) as ToolCardContext["livePendingAction"]
  }
}

const SINGLE_RESULT = {
  pending_action_id: 501,
  pending_confirmation_id: 501,
  state: "pending",
  message: "Pause scheduling for very-long-operator-email@example.test?"
}

function livePendingAction(state: "confirmed" | "rejected", reason: string) {
  return {
    id: 501,
    action: "admin_pause_user_scheduling",
    state,
    label: "Pause user scheduling",
    detail: "user_id: 17",
    reason,
    app_confirm_path: "/confirm",
    app_reject_path: "/reject"
  }
}

describe("admin_pause_user_scheduling tool card", () => {
  it("registers namespaced calls under the exact MCP tool name", () => {
    const rawName = "mcp__syrus-chat-sidecar__admin_pause_user_scheduling"

    expect(normalizedToolName(rawName)).toBe(adminPauseUserSchedulingToolCard.toolName)
    expect(adminPauseUserSchedulingToolCard.toolName).toBe("admin_pause_user_scheduling")
  })

  it.each([
    ["structured_content", { structured_content: SINGLE_RESULT }],
    ["content[0].text", { content: [{ type: "text", text: JSON.stringify(SINGLE_RESULT) }] }]
  ])("normalizes %s results and renders every single-user field", (_label, envelope) => {
    const parsedResult = normalizedToolCardParsedResult(redactToolCardValue(envelope))
    const cardContext = context(parsedResult, {
      input: {
        user_id: 17,
        reason: "Pause while **billing access** is reviewed."
      }
    })

    expect(adminPauseUserSchedulingToolCard.collapsedSummary?.(cardContext)).toBeNull()
    expect(adminPauseUserSchedulingToolCard.argumentSummary?.(cardContext.input)).toBe("")
    render(<>{adminPauseUserSchedulingToolCard.renderExpanded(cardContext)}</>)

    expect(screen.getByText("pending")).toBeInTheDocument()
    expect(screen.getByText("Pending action #501")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "17" })).toHaveAttribute("href", "/admin/users/17")
    expect(screen.getByRole("button", { name: "Copy 17 to clipboard" })).toBeInTheDocument()
    expect(screen.getByText("billing access").tagName).toBe("STRONG")
    expect(screen.getByRole("link", { name: "very-long-operator-email@example.test" })).toHaveAttribute("href", "mailto:very-long-operator-email@example.test")
  })

  it("renders bulk user ids, group details, member count, and confirmed state", () => {
    const cardContext = context(
      {
        ...SINGLE_RESULT,
        pending_action_group_id: 82,
        member_count: 2,
        message: "Pause scheduling for 2 users."
      },
      {
        input: { user_ids: [17, 29], reason: "**Incident containment**" },
        livePendingAction: livePendingAction("confirmed", "Approved by user #4.")
      }
    )

    render(<>{adminPauseUserSchedulingToolCard.renderExpanded(cardContext)}</>)

    expect(adminPauseUserSchedulingToolCard.collapsedSummary?.(cardContext)).toBeNull()
    expect(screen.getByText("confirmed")).toBeInTheDocument()
    expect(screen.getByText("Pending action group #82")).toBeInTheDocument()
    expect(screen.getByText("2 actions")).toBeInTheDocument()
    for (const id of ["17", "29"]) {
      expect(screen.getByRole("link", { name: id })).toHaveAttribute("href", `/admin/users/${id}`)
      expect(screen.getByRole("button", { name: `Copy ${id} to clipboard` })).toBeInTheDocument()
    }
    expect(screen.getByText("Incident containment").tagName).toBe("STRONG")
    expect(screen.getByRole("link", { name: "user #4" })).toHaveAttribute("href", "/admin/users/4")
  })

  it("leaves successful collapsed rows free of a narrow detail column", () => {
    const result = {
      ...SINGLE_RESULT,
      pending_action_group_id: 82,
      member_count: 2,
      message: "Pause scheduling for 2 users."
    }
    const body = JSON.stringify(result)

    expect(
      toolResultPresentation("mcp__syrus-chat-sidecar__admin_pause_user_scheduling", body, false, body, { user_ids: [17, 29] }, result).summary
    ).toBe("")
  })

  it("renders the live rejected state and reason", () => {
    const cardContext = context(SINGLE_RESULT, {
      input: { user_id: 17, reason: "Requested by **security**." },
      livePendingAction: livePendingAction("rejected", "Rejected after operator review.")
    })

    render(<>{adminPauseUserSchedulingToolCard.renderExpanded(cardContext)}</>)

    expect(adminPauseUserSchedulingToolCard.collapsedSummary?.(cardContext)).toBeNull()
    expect(screen.getByText("rejected")).toBeInTheDocument()
    expect(screen.getByText("Rejected after operator review.")).toBeInTheDocument()
  })

  it("renders redacted inputs alongside a provider error without overflowing", () => {
    const secret = "super-secret-value"
    const cardContext = context(
      { content: [{ type: "text", text: `Provider rejected token=${secret}` }] },
      {
        resultError: true,
        input: {
          user_id: 17,
          reason: `Investigate authorization=${secret} before retrying. ${"Long context. ".repeat(80)}`
        }
      }
    )

    render(<>{adminPauseUserSchedulingToolCard.renderExpanded(cardContext)}</>)

    expect(adminPauseUserSchedulingToolCard.collapsedSummary?.(cardContext)).toBe("Error")
    expect(screen.getByText("failed")).toBeInTheDocument()
    expect(screen.getAllByText(/\[redacted\]/).length).toBeGreaterThan(0)
    expect(screen.queryByText(new RegExp(secret))).not.toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Show more" })).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "17" }).parentElement).toHaveClass("min-w-0")
  })
})
