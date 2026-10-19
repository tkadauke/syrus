import { fireEvent, render, screen, within } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import commentOnDesignDocToolCard from "./comment_on_design_doc"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "comment_on_design_doc",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

const parsedResult = {
  design_doc: { doc_ref: "DOC-20", title: "Target Graphs", visibility: "public", state: "draft" },
  doc_ref: "DOC-20",
  thread: { id: 1, state: "open", anchor: { start_offset: 10, end_offset: 31, selected_markdown: "**selected section**" }, comments: [{ id: 5 }] },
  comment: { id: 5, author_kind: "agent", body: "This section needs a **diagram**." },
  version: { version_number: 3 },
  mutation_mode: "comment_only"
}

describe("comment_on_design_doc tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(commentOnDesignDocToolCard.toolName).toBe("comment_on_design_doc")
  })

  it("summarizes the collapsed row with the doc ref", () => {
    expect(commentOnDesignDocToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("Commented on DOC-20")
  })

  it("renders all result metadata, markdown, and an anchored doc link", () => {
    render(<>{commentOnDesignDocToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("DOC-20")).toBeInTheDocument()
    expect(screen.getByText("open")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "DOC-20" })).toHaveAttribute("href", "/design_docs/20#thread-1")
    expect(screen.getByText("selected section").tagName).toBe("STRONG")
    expect(screen.getByText("diagram").tagName).toBe("STRONG")
    expect(screen.getByText("10–31")).toBeInTheDocument()
    expect(screen.getByText("agent")).toBeInTheDocument()
    expect(screen.getByText("v3")).toBeInTheDocument()
    expect(screen.getByText("comment only")).toBeInTheDocument()
    expect(screen.getByText("New thread")).toBeInTheDocument()
  })

  it("uses input anchor fields and expands a long markdown body", () => {
    const longBody = `${"Long **comment** text. ".repeat(80)}\n\n## Ending\nComplete.`
    const result = {
      ...parsedResult,
      thread: { id: 2, state: "open", comments: [{ id: 1 }, { id: 2 }] },
      comment: { id: 2, author_kind: "agent", body: longBody }
    }
    render(
      <>
        {commentOnDesignDocToolCard.renderExpanded(
          context({ input: { start_offset: 4, end_offset: 12, selected_markdown: "fallback quote" }, parsedResult: result })
        )}
      </>
    )

    expect(screen.getByText("4–12")).toBeInTheDocument()
    expect(screen.getByText("fallback quote")).toBeInTheDocument()
    expect(screen.getByText("Reply")).toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: "Show more" }))
    expect(within(screen.getByRole("dialog", { name: "Full comment" })).getByRole("heading", { name: "Ending" })).toBeInTheDocument()
  })

  it("renders text and structured error envelopes plus pending state", () => {
    const { rerender } = render(<>{commentOnDesignDocToolCard.renderExpanded(context({ resultBody: "Error: not allowed", resultError: true }))}</>)
    expect(screen.getByRole("alert")).toHaveTextContent("not allowed")

    rerender(
      <>
        {commentOnDesignDocToolCard.renderExpanded(
          context({ resultBody: JSON.stringify({ error: "anchor not found" }), parsedResult: { error: "anchor not found" }, resultError: true })
        )}
      </>
    )
    expect(screen.getByRole("alert")).toHaveTextContent("anchor not found")

    rerender(<>{commentOnDesignDocToolCard.renderExpanded(context())}</>)
    expect(screen.getByText("Waiting for the tool result.")).toBeInTheDocument()
  })

  it("renders explicit empty states for blank body and selection", () => {
    const result = { ...parsedResult, thread: { id: 1, state: "open", comments: [] }, comment: { id: 5, author_kind: "agent", body: " " } }
    render(<>{commentOnDesignDocToolCard.renderExpanded(context({ parsedResult: result }))}</>)
    expect(screen.getByText("No selected text was returned.")).toBeInTheDocument()
    expect(screen.getByText("No content.")).toBeInTheDocument()
  })

  it("falls back to null for a malformed payload (missing comment)", () => {
    expect(commentOnDesignDocToolCard.collapsedSummary?.(context({ parsedResult: { design_doc: parsedResult.design_doc } }))).toBeNull()
    expect(commentOnDesignDocToolCard.renderExpanded(context({ parsedResult: { design_doc: parsedResult.design_doc } }))).toBeNull()
  })

  it("falls back to null for a non-object payload", () => {
    expect(commentOnDesignDocToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
