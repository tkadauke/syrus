import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import listChatsToolCard from "./list_chats"
import searchChatsToolCard from "./search_chats"
import readChatMessagesToolCard from "./read_chat_messages"

function context(toolName: string, overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName,
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

describe("chat search/history tool cards", () => {
  it("registers under the exact MCP tool names", () => {
    expect(listChatsToolCard.toolName).toBe("list_chats")
    expect(searchChatsToolCard.toolName).toBe("search_chats")
    expect(readChatMessagesToolCard.toolName).toBe("read_chat_messages")
  })

  it("renders chat list rows with repository, timestamps, pagination, and chat links", () => {
    const parsedResult = {
      chats: [
        { id: 42, title: "Landing queue notes", repository: "acme/widgets", message_count: 9, updated_at: "2026-09-01T12:00:00Z" }
      ],
      pagination: { page: 1, per_page: 20, total_count: 1, total_pages: 1, has_next_page: false }
    }

    expect(listChatsToolCard.collapsedSummary?.(context("list_chats", { parsedResult }))).toBe("1 chat")
    render(<>{listChatsToolCard.renderExpanded(context("list_chats", { parsedResult }))}</>)

    expect(screen.getByRole("link", { name: "Landing queue notes" })).toHaveAttribute("href", "/chats/42")
    expect(screen.getByText("acme/widgets")).toBeInTheDocument()
    expect(screen.getByText("9 messages")).toBeInTheDocument()
    expect(screen.getByText("Page 1 of 1 · 1 total")).toBeInTheDocument()
  })

  it("renders empty list and search states", () => {
    render(<>{listChatsToolCard.renderExpanded(context("list_chats", { parsedResult: { chats: [], pagination: { total_count: 0 } } }))}</>)
    expect(screen.getByText("No chats found.")).toBeInTheDocument()

    render(<>{searchChatsToolCard.renderExpanded(context("search_chats", { parsedResult: { results: [], message: "No matching messages found." } }))}</>)
    expect(screen.getByText("No matching messages found.")).toBeInTheDocument()
  })

  it("renders search hits with match counts, snippets, and message anchors", () => {
    const parsedResult = {
      results: [
        { chat_session_id: 42, message_id: 100, chat_title: "Landing queue notes", repository: "acme/widgets", role: "assistant", snippet: "Found <b>needle</b> in the queue.", created_at: "2026-09-01T12:00:00Z" },
        { chat_session_id: 42, message_id: 101, chat_title: "Landing queue notes", repository: "acme/widgets", role: "user", snippet: "Another <b>needle</b>.", created_at: "2026-09-01T12:01:00Z" }
      ]
    }

    expect(searchChatsToolCard.collapsedSummary?.(context("search_chats", { input: { query: "needle" }, parsedResult }))).toBe("\"needle\" - 2 hits")
    render(<>{searchChatsToolCard.renderExpanded(context("search_chats", { input: { query: "needle" }, parsedResult }))}</>)

    expect(screen.getAllByRole("link", { name: "Landing queue notes" })[0]).toHaveAttribute("href", "/chats/42#message-100")
    expect(screen.getAllByText("2 matches in chat")).toHaveLength(2)
    expect(document.querySelectorAll("mark")).toHaveLength(2)
    expect(screen.getByText("assistant")).toBeInTheDocument()
  })

  it("renders transcript excerpts with metadata, safe truncation, anchors, and pagination state", () => {
    const parsedResult = {
      chat_title: "Current chat",
      page: 1,
      has_more: true,
      next_page: 2,
      messages: [
        { id: 7, role: "user", content: { text: `${"Long message ".repeat(80)}end` }, created_at: "2026-09-01T12:00:00Z" },
        { id: 8, role: "assistant", content: { text: "Short reply" }, created_at: "2026-09-01T12:01:00Z" }
      ]
    }

    expect(readChatMessagesToolCard.collapsedSummary?.(context("read_chat_messages", { input: { chat_session_id: 42 }, parsedResult }))).toBe("Current chat - 2 messages")
    render(<>{readChatMessagesToolCard.renderExpanded(context("read_chat_messages", { input: { chat_session_id: 42 }, parsedResult }))}</>)

    expect(screen.getByRole("link", { name: "Current chat" })).toHaveAttribute("href", "/chats/42")
    expect(screen.getByText("older messages available")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "message 7" })).toHaveAttribute("href", "/chats/42#message-7")
    expect(screen.getByText(/Long message/).textContent?.endsWith("...")).toBe(true)
    expect(screen.getByText("Next page: 2")).toBeInTheDocument()
  })

  it("falls back to the generic renderer for malformed payloads", () => {
    expect(listChatsToolCard.renderExpanded(context("list_chats", { parsedResult: { oops: true } }))).toBeNull()
    expect(searchChatsToolCard.renderExpanded(context("search_chats", { parsedResult: "not json" }))).toBeNull()
    expect(readChatMessagesToolCard.renderExpanded(context("read_chat_messages", { parsedResult: { messages: "nope" } }))).toBeNull()
  })
})
