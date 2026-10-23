import { fireEvent, render, screen } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { describe, expect, it, vi } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import { normalizedToolCardParsedResult, normalizedToolName, parseJsonText } from "../toolRendering"
import sendChatMessageToolCard from "./send_chat_message"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  const resultBody = overrides.resultBody ?? ""
  const rawParsed = overrides.parsedResult === undefined ? parseJsonText(resultBody) : overrides.parsedResult
  return {
    resultBody,
    resultError: false,
    ...overrides,
    toolName: normalizedToolName(overrides.toolName ?? "send_chat_message"),
    parsedResult: normalizedToolCardParsedResult(rawParsed)
  }
}

const success = { thread_id: 7, state: "open", hop_count: 1, max_hops: 6, hops_remaining: 5, target_chat_session_id: 42, message_id: 99 }

describe("send_chat_message tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(sendChatMessageToolCard.toolName).toBe("send_chat_message")
  })

  it("summarizes the target chat and thread", () => {
    expect(sendChatMessageToolCard.collapsedSummary?.(context({ parsedResult: success }))).toBe("Sent to CHAT-42 (thread #7)")
  })

  it("renders markdown prose, linked targets, thread state, and every hop field", () => {
    const text = `Review **the change** at https://example.test/context.\n${"More context. ".repeat(80)}`
    render(
      <MemoryRouter>
        {sendChatMessageToolCard.renderExpanded(context({ input: { text, target_chat_session_id: 42, max_hops: 6 }, parsedResult: success }))}
      </MemoryRouter>
    )

    expect(screen.getByText("Cross-chat message")).toBeInTheDocument()
    expect(screen.getByText("open")).toBeInTheDocument()
    expect(screen.getByText("the change").tagName).toBe("STRONG")
    expect(screen.getByRole("link", { name: "https://example.test/context" })).toHaveAttribute("href", "https://example.test/context")
    expect(screen.getAllByRole("link", { name: "CHAT-42" })).toHaveLength(2)
    expect(screen.getAllByRole("link", { name: "CHAT-42" })[0]).toHaveAttribute("href", "/chats/42")
    expect(screen.getByRole("link", { name: "Message #99" })).toHaveAttribute("href", "/chats/42#message-99")
    expect(screen.getByText("#7")).toBeInTheDocument()
    expect(screen.getByText("1 / 6")).toBeInTheDocument()
    expect(screen.getByText("Hops left")).toBeInTheDocument()
    expect(screen.getByText("5")).toBeInTheDocument()
    expect(screen.getByText("Requested hop cap")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Show more" })).toHaveClass("min-h-11")
    expect(screen.getByTestId("markdown-preview-content")).toHaveClass("break-words", "[overflow-wrap:anywhere]")

    fireEvent.click(screen.getByRole("button", { name: "Show more" }))
    expect(screen.getByRole("dialog", { name: "Sent message" })).toBeInTheDocument()
  })

  it("shows the input thread when replying to an existing bridge", () => {
    render(<MemoryRouter>{sendChatMessageToolCard.renderExpanded(context({ input: { text: "Reply", thread_id: 7 }, parsedResult: success }))}</MemoryRouter>)
    expect(screen.getByText("Requested thread")).toBeInTheDocument()
    expect(screen.getAllByText("#7")).toHaveLength(2)
  })

  it("passes markdown link clicks to the chat surface interceptor", () => {
    const onLinkClick = vi.fn()
    render(
      <MemoryRouter>
        {sendChatMessageToolCard.renderExpanded(
          context({
            input: { text: "Open [the workspace file](/syrus-home/.syrus/chat-workspaces/122/repositories/tkadauke/syrus/app/models/job.rb)", thread_id: 7 },
            onLinkClick,
            parsedResult: success
          })
        )}
      </MemoryRouter>
    )

    fireEvent.click(screen.getByRole("link", { name: "the workspace file" }))
    expect(onLinkClick).toHaveBeenCalledWith("/syrus-home/.syrus/chat-workspaces/122/repositories/tkadauke/syrus/app/models/job.rb", expect.any(Object))
  })

  it("renders a closed thread state after the hop cap is reached", () => {
    const parsedResult = { thread_id: 7, state: "closed", hop_count: 6, max_hops: 6, hops_remaining: 0, target_chat_session_id: 42, message_id: 99 }

    render(<>{sendChatMessageToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("closed")).toBeInTheDocument()
    expect(screen.getByText("6 / 6")).toBeInTheDocument()
    expect(screen.getByText("0")).toBeInTheDocument()
  })

  it.each(["a new bridge thread can only be opened directly from the operator's own message", "cannot open a bridge thread to the same chat"])(
    "renders invalid requests with ErrorCard: %s",
    (message) => {
      render(<>{sendChatMessageToolCard.renderExpanded(context({ resultError: true, resultBody: message }))}</>)
      expect(screen.getByText("failed")).toBeInTheDocument()
      expect(screen.getByText(message)).toBeInTheDocument()
    }
  )

  it("renders pending, blank-message, and routing input states", () => {
    const pending = context({ input: { text: "", target_chat_session_id: 42, thread_id: 7, max_hops: 9 } })
    expect(sendChatMessageToolCard.collapsedSummary?.(pending)).toBe("Cross-chat message pending")
    render(<>{sendChatMessageToolCard.renderExpanded(pending)}</>)
    expect(screen.getByText("pending")).toBeInTheDocument()
    expect(screen.getByText("No message text was included with this transcript entry.")).toBeInTheDocument()
    expect(screen.getByText("Requested target")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "CHAT-42" })).toHaveAttribute("href", "/chats/42")
    expect(screen.getByText("Requested thread")).toBeInTheDocument()
    expect(screen.getByText("#7")).toBeInTheDocument()
    expect(screen.getByText("Requested hop cap")).toBeInTheDocument()
    expect(screen.getByText("9")).toBeInTheDocument()
    expect(screen.getByText("Waiting for the message to be sent.")).toBeInTheDocument()
  })

  it("normalizes direct, JSON-body, and Codex-wrapped result envelopes", () => {
    const contexts = [
      context({ parsedResult: success }),
      context({ resultBody: JSON.stringify(success) }),
      context({
        toolName: "mcp__syrus-chat-sidecar__send_chat_message",
        parsedResult: { content: [{ type: "text", text: JSON.stringify(success) }], structured_content: null }
      })
    ]
    for (const toolContext of contexts) {
      expect(toolContext.toolName).toBe("send_chat_message")
      expect(sendChatMessageToolCard.collapsedSummary?.(toolContext)).toBe("Sent to CHAT-42 (thread #7)")
    }
  })

  it("renders a malformed-response fallback for an unexpected payload", () => {
    expect(sendChatMessageToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBe("Cross-chat message returned an unexpected response")
    render(<>{sendChatMessageToolCard.renderExpanded(context({ parsedResult: "not json" }))}</>)
    expect(screen.getByText("Unexpected tool response.")).toBeInTheDocument()
  })
})
