import { fireEvent, render, screen, within } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import listChatsToolCard from "./list_chats"
import searchChatsToolCard from "./search_chats"
import readChatMessagesToolCard from "./read_chat_messages"
import { normalizedToolCardParsedResult, normalizedToolName } from "../toolRendering"

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

  it("renders chat list rows with mode, linked entities, attached Jobs, filters, timestamps, and pagination", () => {
    const parsedResult = {
      chats: [
        {
          id: 42,
          title: "Landing queue notes",
          mode: "coding",
          repository_id: 7,
          repository: "acme/widgets",
          message_count: 9,
          updated_at: "2026-09-01T12:00:00Z",
          attached_jobs_count: 1,
          attached_jobs: [{ id: 101, slug: "repair-queue", title: "Repair queue", state: "running", repository_id: 7, repository: "acme/widgets" }]
        }
      ],
      pagination: { page: 1, per_page: 20, total_count: 1, total_pages: 1, has_next_page: false }
    }

    expect(listChatsToolCard.collapsedSummary?.(context("list_chats", { parsedResult }))).toBe("1 chat")
    render(<>{listChatsToolCard.renderExpanded(context("list_chats", { input: { mode: "coding", job_id: 101, has_attached_jobs: true }, parsedResult }))}</>)

    expect(screen.getByRole("link", { name: "Landing queue notes" })).toHaveAttribute("href", "/chats/42")
    expect(screen.getAllByRole("link", { name: "acme/widgets" })[0]).toHaveAttribute("href", "/repositories/7")
    expect(screen.getByRole("link", { name: "repair-queue" })).toHaveAttribute("href", "/jobs/101")
    expect(screen.getByText("Repair queue")).toBeInTheDocument()
    expect(screen.getByText("running")).toBeInTheDocument()
    expect(screen.getByText("coding")).toBeInTheDocument()
    expect(screen.getByText("Mode: coding")).toBeInTheDocument()
    expect(screen.getByText("Job:")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "JOB-101" })).toHaveAttribute("href", "/jobs/101")
    expect(screen.getByText("Has attached Jobs")).toBeInTheDocument()
    expect(screen.getByText("9 messages")).toBeInTheDocument()
    expect(screen.getByText("1 attached Job")).toBeInTheDocument()
    expect(screen.getByText("Page 1 of 1 · 1 total · End of results")).toBeInTheDocument()
  })

  it("renders empty list and search states", () => {
    render(
      <>
        {listChatsToolCard.renderExpanded(
          context("list_chats", { input: { has_attached_jobs: false }, parsedResult: { chats: [], pagination: { total_count: 0, has_next_page: false } } })
        )}
      </>
    )
    expect(screen.getByText("No chats found.")).toBeInTheDocument()
    expect(screen.getByText("No attached Jobs")).toBeInTheDocument()
    expect(screen.getByText("0 total · End of results")).toBeInTheDocument()

    render(<>{searchChatsToolCard.renderExpanded(context("search_chats", { parsedResult: { results: [], message: "No matching messages found." } }))}</>)
    expect(screen.getByText("No matching messages found.")).toBeInTheDocument()
  })

  it("renders a dedicated error card even when the error body is not JSON", () => {
    const error = context("list_chats", { resultError: true, resultBody: "Chat service unavailable", parsedResult: null })
    expect(listChatsToolCard.collapsedSummary?.(error)).toBeNull()
    render(<>{listChatsToolCard.renderExpanded(error)}</>)

    expect(screen.getByText("Could not list chats")).toBeInTheDocument()
    expect(screen.getByText("Chat service unavailable")).toBeInTheDocument()
    expect(screen.getByText("failed")).toBeInTheDocument()
  })

  it("normalizes provider-prefixed names and MCP result envelopes before rendering", () => {
    const payload = {
      chats: [{ id: 42, title: "Envelope chat", mode: "planning", attached_jobs_count: 0, attached_jobs: [] }],
      pagination: { total_count: 1, has_next_page: true }
    }
    const envelope = { content: [{ type: "text", text: JSON.stringify(payload) }] }

    expect(normalizedToolName("mcp__syrus-chat-sidecar__list_chats")).toBe("list_chats")
    const parsedResult = normalizedToolCardParsedResult(envelope)
    expect(listChatsToolCard.collapsedSummary?.(context(normalizedToolName("syrus-chat-sidecar.list_chats"), { parsedResult }))).toBe("1 chat")
    render(<>{listChatsToolCard.renderExpanded(context("list_chats", { parsedResult }))}</>)
    expect(screen.getByRole("link", { name: "Envelope chat" })).toHaveAttribute("href", "/chats/42")
    expect(screen.getByText("1 total · More available")).toBeInTheDocument()
  })

  it("renders search hits with mode, linked context, attached Jobs, safe markdown, and message anchors", () => {
    const parsedResult = {
      results: [
        {
          chat_session_id: 42,
          message_id: 100,
          chat_title: "Landing queue notes",
          mode: "coding",
          repository_id: 7,
          repository: "acme/widgets",
          role: "assistant",
          snippet: `${"Review **JOB-101** before the <b>needle</b>. See https://example.test/runbook. ".repeat(10)}<script>alert('no')</script>`,
          created_at: "2026-09-01T12:00:00Z",
          attached_jobs_count: 1,
          attached_jobs: [
            {
              id: 101,
              slug: "repair-queue",
              title: "Repair queue",
              state: "running",
              repository_id: 8,
              repository: "acme/worker"
            }
          ]
        },
        {
          chat_session_id: 42,
          message_id: 101,
          chat_title: "Landing queue notes",
          repository: "acme/widgets",
          role: "user",
          snippet: "Another <b>needle</b>.",
          created_at: "2026-09-01T12:01:00Z"
        }
      ]
    }

    expect(searchChatsToolCard.collapsedSummary?.(context("search_chats", { input: { query: "needle" }, parsedResult }))).toBe('"needle" - 2 hits')
    render(<>{searchChatsToolCard.renderExpanded(context("search_chats", { input: { query: "needle", limit: 20 }, parsedResult }))}</>)

    expect(screen.getAllByRole("link", { name: "Landing queue notes" })[0]).toHaveAttribute("href", "/chats/42#message-100")
    expect(screen.getAllByText("2 matches in chat")).toHaveLength(2)
    expect(screen.getByText("coding")).toBeInTheDocument()
    expect(screen.getAllByRole("link", { name: "acme/widgets" })[0]).toHaveAttribute("href", "/repositories/7")
    expect(screen.getByRole("link", { name: "repair-queue" })).toHaveAttribute("href", "/jobs/101")
    expect(screen.getByRole("link", { name: "acme/worker" })).toHaveAttribute("href", "/repositories/8")
    expect(screen.getByText("1 attached Job")).toBeInTheDocument()
    expect(screen.getByText("20")).toBeInTheDocument()
    expect(document.querySelector("script")).not.toBeInTheDocument()
    expect(screen.getAllByText("needle").some((element) => element.tagName === "STRONG")).toBe(true)
    expect(screen.getAllByRole("link", { name: "https://example.test/runbook" })[0]).toHaveAttribute("href", "https://example.test/runbook")
    fireEvent.click(screen.getByRole("button", { name: "Show more" }))
    expect(within(screen.getByRole("dialog", { name: "Message match in Landing queue notes" })).getByRole("button", { name: "Copy text" })).toBeInTheDocument()
    expect(screen.getByText("assistant")).toBeInTheDocument()
  })

  it("renders admin-visible chat and message deletion metadata", () => {
    const parsedResult = {
      results: [
        {
          chat_session_id: 42,
          message_id: 100,
          chat_title: "Deleted discussion",
          snippet: "A <b>needle</b> match.",
          chat_session_deleted_at: "2026-09-02T12:00:00Z",
          chat_session_deleted_by: { id: 1, name: "Chat Admin" },
          deleted_at: "2026-09-02T11:00:00Z",
          deleted_by: { id: 2, email: "moderator@example.test" }
        }
      ]
    }

    render(<>{searchChatsToolCard.renderExpanded(context("search_chats", { parsedResult }))}</>)

    expect(screen.getAllByText("deleted")).toHaveLength(2)
    expect(screen.getByText(/Chat by Chat Admin/)).toBeInTheDocument()
    expect(screen.getByText(/Message by moderator@example.test/)).toBeInTheDocument()
  })

  it("renders message-only empty envelopes and search errors", () => {
    const { unmount } = render(
      <>
        {searchChatsToolCard.renderExpanded(
          context("search_chats", { input: { query: "missing", limit: 5 }, parsedResult: { message: "No matching messages found." } })
        )}
      </>
    )
    expect(screen.getByText("No matching messages found.")).toBeInTheDocument()
    expect(screen.getByText("missing")).toBeInTheDocument()
    expect(screen.getByText("5")).toBeInTheDocument()
    unmount()

    render(<>{searchChatsToolCard.renderExpanded(context("search_chats", { resultError: true, resultBody: "Search unavailable" }))}</>)
    expect(screen.getByText("Could not search chats")).toBeInTheDocument()
    expect(screen.getByText("Search unavailable")).toBeInTheDocument()
  })

  it("normalizes provider-prefixed search names and differently shaped envelopes", () => {
    const payload = { results: [{ chat_session_id: 42, message_id: 100, chat_title: "Envelope result", snippet: "Found it" }] }
    const parsedResult = normalizedToolCardParsedResult({ structured_content: payload })

    expect(normalizedToolName("mcp__custom-provider__search_chats")).toBe("search_chats")
    render(<>{searchChatsToolCard.renderExpanded(context(normalizedToolName("custom-provider.search_chats"), { parsedResult }))}</>)
    expect(screen.getByRole("link", { name: "Envelope result" })).toHaveAttribute("href", "/chats/42#message-100")
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

    expect(readChatMessagesToolCard.collapsedSummary?.(context("read_chat_messages", { input: { chat_session_id: 42 }, parsedResult }))).toBe(
      "Current chat - 2 messages"
    )
    render(<>{readChatMessagesToolCard.renderExpanded(context("read_chat_messages", { input: { chat_session_id: 42 }, parsedResult }))}</>)

    expect(screen.getByRole("link", { name: "Current chat" })).toHaveAttribute("href", "/chats/42")
    expect(screen.getByText("more messages available")).toBeInTheDocument()
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
