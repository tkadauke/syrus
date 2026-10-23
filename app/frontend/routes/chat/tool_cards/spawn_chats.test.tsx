import { fireEvent, render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ChatPendingActionInline } from "@app/api/chats"
import type { ToolCardContext } from "@app/pluginToolCards"
import { normalizedToolCardParsedResult, normalizedToolName } from "../toolRendering"
import spawnChatsToolCard from "./spawn_chats"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return { toolName: "spawn_chats", resultBody: "", resultError: false, parsedResult: null, ...overrides }
}

function pending(overrides: Record<string, unknown> = {}) {
  return {
    pending_action_group_id: 8,
    pending_action_id: 11,
    pending_confirmation_id: 11,
    state: "pending",
    member_count: 2,
    message: "Spawn 2 chats?",
    ...overrides
  }
}

function live(overrides: Partial<ChatPendingActionInline> = {}): ChatPendingActionInline {
  return {
    id: 11,
    action: "spawn_chat",
    state: "pending",
    label: "Spawn chat",
    detail: null,
    app_confirm_path: "/confirm",
    app_reject_path: "/reject",
    ...overrides
  }
}

const input = {
  chats: [
    { title: "Bug hunt", prompt: "Inspect **JOB-42** and https://example.com/very/long/path", provider: "codex", repository: "acme/widgets" },
    { prompt: "Review API\n" + "details ".repeat(150), provider: "claude" }
  ],
  reason: "Run these in **parallel**."
}

describe("spawn_chats tool card", () => {
  it("renders pending chat details, markdown, links, and show-more content", () => {
    render(<>{spawnChatsToolCard.renderExpanded(context({ input, parsedResult: pending() }))}</>)

    expect(screen.getByText("Bug hunt")).toBeInTheDocument()
    expect(screen.getByText("codex")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "acme/widgets" })).toHaveAttribute("href", "https://github.com/acme/widgets")
    expect(screen.getByRole("link", { name: "https://example.com/very/long/path" })).toBeInTheDocument()
    expect(screen.getByText("pending")).toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: "Show more" }))
    expect(screen.getByRole("dialog", { name: "Chat 2 prompt" })).toBeInTheDocument()
  })

  it("renders confirmed spawned chat links from the live outcome", () => {
    render(
      <>
        {spawnChatsToolCard.renderExpanded(
          context({ input, parsedResult: pending(), livePendingAction: live({ state: "confirmed", outcome: { chat_ids: [101, "102"] } }) })
        )}
      </>
    )

    expect(screen.getByText("confirmed")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "CHAT-101" })).toHaveAttribute("href", "/chats/101")
    expect(screen.getByRole("link", { name: "CHAT-102" })).toHaveAttribute("href", "/chats/102")
  })

  it("renders rejected state and blank input states", () => {
    render(
      <>
        {spawnChatsToolCard.renderExpanded(
          context({ input: { chats: [] }, parsedResult: pending(), livePendingAction: live({ state: "rejected", reason: "Too expensive" }) })
        )}
      </>
    )

    expect(screen.getByText("rejected")).toBeInTheDocument()
    expect(screen.getByText("Too expensive")).toBeInTheDocument()
    expect(screen.getByText("No chats supplied.")).toBeInTheDocument()
    expect(screen.getByText("No reason supplied.")).toBeInTheDocument()
  })

  it.each([
    { error: "chat 1 prompt must not be blank" },
    { error: "chat 1 provider is unknown or not configured" },
    { error: "chat 1 repository is not accessible" }
  ])("renders validation errors", (parsedResult) => {
    const { unmount } = render(<>{spawnChatsToolCard.renderExpanded(context({ input, parsedResult }))}</>)
    expect(screen.getByText(parsedResult.error)).toBeInTheDocument()
    expect(screen.getByText("Spawn chats failed")).toBeInTheDocument()
    unmount()
  })

  it("supports normalized names and provider envelopes", () => {
    const claudeEnvelope = { content: [{ type: "text", text: JSON.stringify(pending()) }] }
    const codexEnvelope = { content: [{ type: "text", text: JSON.stringify(pending()) }], structuredContent: null }
    expect(normalizedToolName("mcp__syrus-chat__spawn_chats")).toBe("spawn_chats")
    expect(spawnChatsToolCard.collapsedSummary?.(context({ parsedResult: normalizedToolCardParsedResult(claudeEnvelope) }))).toContain("Spawn 2 chats?")
    expect(spawnChatsToolCard.collapsedSummary?.(context({ parsedResult: normalizedToolCardParsedResult(codexEnvelope) }))).toContain("Spawn 2 chats?")
  })

  it("falls back for malformed results", () => {
    expect(spawnChatsToolCard.renderExpanded(context({ input, parsedResult: { unexpected: true } }))).toBeNull()
  })
})
