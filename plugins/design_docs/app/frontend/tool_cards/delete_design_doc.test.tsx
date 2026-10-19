import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import { normalizedToolCardParsedResult, normalizedToolName } from "@app/routes/chat/toolRendering"
import deleteDesignDocToolCard from "./delete_design_doc"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "delete_design_doc",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

const archived = {
  archived: true,
  immediate: true,
  doc_ref: "DOC-42",
  title: "Temporary **draft**",
  previous_state: "draft",
  new_state: "archived",
  reason: "Fresh doc; see JOB-7 and https://example.test/archive for context."
}

const pending = {
  pending_confirmation_id: 91,
  pending_action_id: 91,
  state: "pending",
  message: "Archive DOC-42?",
  doc_ref: "DOC-42",
  title: "Established design",
  confirmation_required: true,
  confirmation_reason: "Doc has **2 comments**.",
  design_doc_id: 42
}

describe("delete_design_doc tool card", () => {
  it("registers under the provider-normalized MCP tool name", () => {
    expect(normalizedToolName("mcp__syrus-chat-sidecar__delete_design_doc")).toBe(deleteDesignDocToolCard.toolName)
    expect(normalizedToolName("syrus-chat-sidecar.delete_design_doc")).toBe(deleteDesignDocToolCard.toolName)
  })

  it("renders an immediate archive with a linked doc, transition, and markdown reason", () => {
    render(<>{deleteDesignDocToolCard.renderExpanded(context({ parsedResult: archived }))}</>)

    expect(screen.getByRole("link", { name: /DOC-42/ })).toHaveAttribute("href", "/design_docs/42")
    expect(screen.getByText("Immediate")).toBeInTheDocument()
    expect(screen.getByText("Temporary **draft**")).toBeInTheDocument()
    expect(screen.getByText("draft")).toBeInTheDocument()
    expect(screen.getAllByText("archived")).toHaveLength(2)
    expect(screen.getByRole("link", { name: "https://example.test/archive" })).toBeInTheDocument()
  })

  it("renders the pending action and follows its live state", () => {
    render(
      <>
        {deleteDesignDocToolCard.renderExpanded(
          context({
            parsedResult: pending,
            livePendingAction: { id: 91, state: "confirmed", reason: "Approved by operator" } as ToolCardContext["livePendingAction"]
          })
        )}
      </>
    )

    expect(screen.getByText("Confirmation required")).toBeInTheDocument()
    expect(screen.getByText("Design doc ID")).toBeInTheDocument()
    expect(screen.getByText("42")).toBeInTheDocument()
    expect(screen.getByText("confirmed")).toBeInTheDocument()
    expect(screen.getByText("Approved by operator")).toBeInTheDocument()
    expect(screen.getByText("2 comments").tagName).toBe("STRONG")
  })

  it.each([
    [{ error: "not allowed to archive DOC-42" }, "not allowed to archive DOC-42"],
    [{ error: { message: "design doc not found" } }, "design doc not found"],
    [{ message: "Could not archive design doc" }, "Could not archive design doc"]
  ])("renders a styled error for %j", (parsedResult, message) => {
    const { unmount } = render(<>{deleteDesignDocToolCard.renderExpanded(context({ parsedResult, resultError: true }))}</>)
    const heading = screen.getAllByText("Could not archive design doc")[0]
    expect(heading.closest("div.rounded")).toHaveClass("bg-danger/10")
    expect(screen.getAllByText(message).length).toBeGreaterThan(0)
    unmount()
  })

  it("renders empty reason fields explicitly", () => {
    render(<>{deleteDesignDocToolCard.renderExpanded(context({ parsedResult: { ...archived, reason: "" } }))}</>)
    expect(screen.getByText("No archive reason provided.")).toBeInTheDocument()
  })

  it("accepts structured-content and text-content MCP envelopes after shared normalization", () => {
    const structured = normalizedToolCardParsedResult({ structured_content: archived })
    const text = normalizedToolCardParsedResult({ content: [{ type: "text", text: JSON.stringify(pending) }] })

    expect(deleteDesignDocToolCard.collapsedSummary?.(context({ parsedResult: structured }))).toBe("Archived DOC-42 — Temporary **draft**")
    expect(deleteDesignDocToolCard.collapsedSummary?.(context({ parsedResult: text }))).toContain("DOC-42")
  })

  it("falls back for an unrelated payload", () => {
    expect(deleteDesignDocToolCard.renderExpanded(context({ parsedResult: { unrelated: true } }))).toBeNull()
  })
})
