import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ChatPendingActionInline } from "@app/api/chats"
import { toolCardContextForExample, type ToolCardContext } from "@app/pluginToolCards"
import { normalizedToolCardParsedResult } from "@app/toolCardParsing"
import { redactToolCardValue } from "@app/toolCardSecurity"
import { normalizedToolName } from "../toolRendering"
import card, { examples } from "./wake_provider_admission"

const result = {
  pending_confirmation_id: 501,
  pending_action_id: 501,
  state: "pending",
  reason: "**Capacity recovered** after reviewing provider evidence.",
  message: "Wake 12 queued codex workflows and 3 delayed auto-retries?",
  observed_preview: {
    provider: "codex",
    workflow_ids: Array.from({ length: 12 }, (_, index) => index + 1),
    workflow_count: 12,
    auto_retry_attempt_ids: [71, 72, 73],
    auto_retry_count: 3
  }
}

function context(parsedResult: unknown, overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "wake_provider_admission",
    input: { provider: "codex", user_id: 9, reason: "**Capacity recovered** after reviewing provider evidence." },
    resultBody: "",
    resultError: false,
    parsedResult: redactToolCardValue(parsedResult),
    ...overrides
  }
}

function liveAction(state: ChatPendingActionInline["state"]): ChatPendingActionInline {
  return {
    id: 501,
    action: "wake_provider_admission",
    state,
    label: "Wake provider admission",
    detail: null,
    app_confirm_path: "/api/v1/app/chats/1/pending_actions/501/confirm",
    app_reject_path: "/api/v1/app/chats/1/pending_actions/501/reject"
  }
}

describe("wake_provider_admission tool card", () => {
  it("exports catalog fixtures for every reviewable action state", () => {
    expect(examples.map((example) => example.id)).toEqual(["pending_scoped_wake", "confirmed_scoped_wake", "rejected_all_users_wake", "preview_error"])

    for (const example of examples) {
      const exampleContext = toolCardContextForExample(card.toolName, example)
      expect(() => card.renderExpanded(exampleContext)).not.toThrow()
    }
  })

  it("renders scoped inputs and labelled preview counts from structured content", () => {
    const rawName = "mcp__syrus-chat-sidecar__wake_provider_admission"
    const parsedResult = normalizedToolCardParsedResult({ structured_content: result })

    expect(normalizedToolName(rawName)).toBe(card.toolName)
    render(<>{card.renderExpanded(context(parsedResult))}</>)

    expect(screen.getByText("codex")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "9" })).toHaveAttribute("href", "/admin/users/9")
    expect(screen.getAllByText("Capacity recovered").length).toBeGreaterThan(0)
    expect(screen.getByText("Queued workflows").nextElementSibling).toHaveTextContent("12")
    expect(screen.getByText("Delayed auto-retries").nextElementSibling).toHaveTextContent("3")
    expect(screen.getByText("pending")).toBeInTheDocument()
  })

  it("normalizes a content text JSON envelope and shows an unscoped wake", () => {
    const envelope = { content: [{ type: "text", text: JSON.stringify(result) }] }
    const parsedResult = normalizedToolCardParsedResult(envelope)

    render(<>{card.renderExpanded(context(parsedResult, { input: { provider: "claude", reason: "Recovered." } }))}</>)

    expect(screen.getByText("claude")).toBeInTheDocument()
    expect(screen.getByText("All users")).toBeInTheDocument()
    expect(screen.getByText("Queued workflows").nextElementSibling).toHaveTextContent("12")
  })

  it.each(["confirmed", "rejected"] as const)("prefers the live %s state", (state) => {
    render(<>{card.renderExpanded(context(result, { livePendingAction: liveAction(state) }))}</>)

    expect(screen.getByText(state)).toBeInTheDocument()
    expect(screen.queryByText("pending")).not.toBeInTheDocument()
  })

  it("renders errors with the requested inputs and without preview counts", () => {
    render(<>{card.renderExpanded(context({ content: [{ type: "text", text: "Provider admission preview failed" }] }, { resultError: true }))}</>)

    expect(screen.getByText("failed")).toBeInTheDocument()
    expect(screen.getByText("Provider admission preview failed")).toBeInTheDocument()
    expect(screen.getByText("codex")).toBeInTheDocument()
    expect(screen.queryByText("Queued workflows")).not.toBeInTheDocument()
  })
})
