import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import sendChatMessageToolCard from "./send_chat_message"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return { toolName: "send_chat_message", resultBody: "", resultError: false, parsedResult: null, ...overrides }
}

describe("send_chat_message tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(sendChatMessageToolCard.toolName).toBe("send_chat_message")
  })

  it("summarizes the target chat and thread", () => {
    const parsedResult = { thread_id: 7, state: "open", hop_count: 1, max_hops: 6, hops_remaining: 5, target_chat_session_id: 42, message_id: 99 }
    expect(sendChatMessageToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("Sent to chat #42 (thread #7)")
  })

  it("renders thread state and hop progress", () => {
    const parsedResult = { thread_id: 7, state: "open", hop_count: 1, max_hops: 6, hops_remaining: 5, target_chat_session_id: 42, message_id: 99 }

    render(<>{sendChatMessageToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("Cross-chat message")).toBeInTheDocument()
    expect(screen.getByText("open")).toBeInTheDocument()
    expect(screen.getByText("#42")).toBeInTheDocument()
    expect(screen.getByText("#7")).toBeInTheDocument()
    expect(screen.getByText("1 / 6")).toBeInTheDocument()
  })

  it("renders a closed thread state after the hop cap is reached", () => {
    const parsedResult = { thread_id: 7, state: "closed", hop_count: 6, max_hops: 6, hops_remaining: 0, target_chat_session_id: 42, message_id: 99 }

    render(<>{sendChatMessageToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("closed")).toBeInTheDocument()
    expect(screen.getByText("6 / 6")).toBeInTheDocument()
  })

  it("renders the tool error message", () => {
    render(<>{sendChatMessageToolCard.renderExpanded(context({ resultError: true, resultBody: "not_authorized" }))}</>)

    expect(screen.getByText("not_authorized")).toBeInTheDocument()
  })

  it("renders a malformed-response fallback for an unexpected payload", () => {
    expect(sendChatMessageToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } })))
      .toBe("Cross-chat message returned an unexpected response")
    render(<>{sendChatMessageToolCard.renderExpanded(context({ parsedResult: "not json" }))}</>)
    expect(screen.getByText("Unexpected tool response.")).toBeInTheDocument()
  })
})
