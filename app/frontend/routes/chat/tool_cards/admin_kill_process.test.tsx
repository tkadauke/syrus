import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ChatPendingActionInline } from "@app/api/chats"
import type { ToolCardContext } from "@app/pluginToolCards"
import { redactToolCardValue } from "@app/toolCardSecurity"
import { normalizedToolCardParsedResult, normalizedToolName } from "../toolRendering"
import adminKillProcessToolCard from "./admin_kill_process"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "admin_kill_process",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

function liveAction(state: "confirmed" | "rejected", reason: string): ChatPendingActionInline {
  return {
    id: 501,
    action: "admin_kill_process",
    state,
    reason,
    label: "Kill process",
    detail: null,
    app_confirm_path: "/api/v1/app/chats/1/pending_actions/501/confirm",
    app_reject_path: "/api/v1/app/chats/1/pending_actions/501/reject"
  }
}

function redacted(value: unknown) {
  return redactToolCardValue(value)
}

describe("admin_kill_process tool card", () => {
  it("registers the normalized sidecar tool name", () => {
    expect(normalizedToolName("mcp__syrus-chat-sidecar__admin_kill_process")).toBe("admin_kill_process")
    expect(adminKillProcessToolCard.toolName).toBe("admin_kill_process")
  })

  it("renders a pending single-process target as a linked, copyable id", () => {
    const parsedResult = redacted({
      pending_action_id: 501,
      pending_confirmation_id: 501,
      state: "pending",
      message: "Kill process #41?"
    })

    render(<>{adminKillProcessToolCard.renderExpanded(context({ input: redacted({ process_id: 41 }) as Record<string, unknown>, parsedResult }))}</>)

    expect(screen.getByText("pending")).toBeInTheDocument()
    expect(screen.getByText("Pending action #501")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "41" })).toHaveAttribute("href", "/admin/processes/41")
    expect(screen.getByRole("button", { name: "Copy 41 to clipboard" })).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "process #41" })).toHaveAttribute("href", "/admin/processes/41")
  })

  it.each([
    ["structured_content", (payload: object) => ({ structured_content: payload, content: [] })],
    ["content text", (payload: object) => ({ structured_content: null, content: [{ type: "text", text: JSON.stringify(payload) }] })]
  ])("renders bulk targets and every result field from %s", (_label, envelope) => {
    const payload = {
      pending_action_group_id: 88,
      pending_action_id: 501,
      pending_confirmation_id: 501,
      state: "pending",
      member_count: 3,
      message: "Kill processes for JOB-42?",
      reason: "The processes exceeded their expected runtime."
    }
    const parsedResult = redacted(normalizedToolCardParsedResult(envelope(payload)))

    render(<>{adminKillProcessToolCard.renderExpanded(context({ input: redacted({ process_ids: [41, 42, 43] }) as Record<string, unknown>, parsedResult }))}</>)

    expect(screen.getByText("Pending action group #88")).toBeInTheDocument()
    expect(screen.getByText("3 actions")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "41" })).toHaveAttribute("href", "/admin/processes/41")
    expect(screen.getByRole("link", { name: "43" })).toHaveAttribute("href", "/admin/processes/43")
    expect(screen.getByText(/Kill processes for JOB-42/)).toHaveAttribute("data-testid", "markdown-preview-content")
    expect(screen.getByText("The processes exceeded their expected runtime.")).toBeInTheDocument()
  })

  it.each([
    ["confirmed", "Approved after reviewing the host."],
    ["rejected", "Keep the process running for diagnostics."]
  ] as const)("renders the live %s state and reason", (state, reason) => {
    const parsedResult = redacted({ pending_action_id: 501, state: "pending", message: "Kill process #41?" })
    render(
      <>
        {adminKillProcessToolCard.renderExpanded(
          context({ input: redacted({ process_id: 41 }) as Record<string, unknown>, parsedResult, livePendingAction: liveAction(state, reason) })
        )}
      </>
    )

    expect(screen.getByText(state)).toBeInTheDocument()
    expect(screen.getByText(reason)).toBeInTheDocument()
  })

  it("renders tool errors with the targeted ids and redacted Markdown prose", () => {
    const input = redacted({ process_ids: [41, 42] }) as Record<string, unknown>
    const parsedResult = redacted({ error: "Authorization: Bearer secret-token-value\n\nRetry after **checking the worker**." })

    render(<>{adminKillProcessToolCard.renderExpanded(context({ input, parsedResult, resultError: true }))}</>)

    expect(screen.getByText("failed")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "41" })).toHaveAttribute("href", "/admin/processes/41")
    expect(screen.getByText(/Authorization: Bearer \[redacted\]/)).toBeInTheDocument()
    expect(screen.getByText("checking the worker")).toBeInTheDocument()
    expect(screen.queryByText(/secret-token-value/)).not.toBeInTheDocument()
  })
})
