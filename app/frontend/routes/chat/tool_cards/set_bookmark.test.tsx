import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import { MemoryRouter } from "react-router-dom"
import type { ToolCardContext } from "@app/pluginToolCards"
import { normalizedToolCardParsedResult, normalizedToolName } from "../toolRendering"
import setBookmarkToolCard from "./set_bookmark"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "set_bookmark",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

describe("set_bookmark tool card", () => {
  it("registers under the provider-normalized MCP tool name", () => {
    expect(setBookmarkToolCard.toolName).toBe("set_bookmark")
    expect(normalizedToolName("mcp__syrus-chat-sidecar__set_bookmark")).toBe(setBookmarkToolCard.toolName)
    expect(normalizedToolName("syrus-chat-sidecar.set_bookmark")).toBe(setBookmarkToolCard.toolName)
  })

  it("summarizes the collapsed row with the label and kind", () => {
    const parsedResult = { id: 4, label: "Launch notes", kind: "topic", message_id: 12, anchor: "message-12" }
    expect(setBookmarkToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("Bookmark added: Launch notes (topic)")
  })

  it("links anchor and message within the current app-shell chat route", () => {
    const parsedResult = { id: 4, label: "Launch notes", kind: "topic", message_id: 12, anchor: "message-12" }
    render(
      <MemoryRouter initialEntries={["/app-shell/chats/42"]}>{setBookmarkToolCard.renderExpanded(context({ parsedResult, chatSessionId: 42 }))}</MemoryRouter>
    )

    expect(screen.getByText("added")).toBeInTheDocument()
    expect(screen.getByText("topic")).toBeInTheDocument()
    expect(screen.getByText("#4")).toBeInTheDocument()
    expect(screen.getByText("Launch notes")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "message-12" })).toHaveAttribute("href", "#message-12")
    expect(screen.getByRole("link", { name: "#12" })).toHaveAttribute("href", "#message-12")
  })

  it("uses label and kind from input and makes the anchor copyable without chat context", () => {
    render(
      <>
        {setBookmarkToolCard.renderExpanded(context({ input: { label: "Epic kickoff", kind: "epic_origin" }, parsedResult: { id: 5, anchor: "message-18" } }))}
      </>
    )

    expect(screen.getByText("Epic kickoff")).toBeInTheDocument()
    expect(screen.getByText("epic_origin")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: /copy message-18 to clipboard/i })).toBeInTheDocument()
  })

  it("renders shared malformed and error states, including an empty response", () => {
    const { rerender } = render(<>{setBookmarkToolCard.renderExpanded(context({ parsedResult: {} }))}</>)
    expect(screen.getByText("Unexpected tool response.")).toBeInTheDocument()
    expect(setBookmarkToolCard.collapsedSummary?.(context({ parsedResult: null }))).toBe("Bookmark returned an unexpected response")

    rerender(<>{setBookmarkToolCard.renderExpanded(context({ resultError: true, parsedResult: null, resultBody: "Error: label is required" }))}</>)
    expect(screen.getByText("Error: label is required")).toBeInTheDocument()
    expect(screen.getByText("failed")).toBeInTheDocument()
  })

  it("renders equivalent Claude and structured-content result envelopes", () => {
    const result = { id: 4, label: "Launch notes", kind: "topic", message_id: 12, anchor: "message-12" }
    const envelopes = [{ structured_content: result }, { content: [{ type: "text", text: JSON.stringify(result) }] }]

    for (const envelope of envelopes) {
      const parsedResult = normalizedToolCardParsedResult(envelope)
      expect(setBookmarkToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("Bookmark added: Launch notes (topic)")
    }
  })
})
