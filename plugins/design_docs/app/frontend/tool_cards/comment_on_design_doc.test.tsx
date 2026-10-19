import { fireEvent, render, screen, within } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import { normalizedToolCardParsedResult } from "@app/routes/chat/toolRendering"
import commentOnDesignDocToolCard, { examples } from "./comment_on_design_doc"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return { toolName: "comment_on_design_doc", resultBody: "settled", resultError: false, parsedResult: null, ...overrides }
}

const longBody = `A **markdown** comment links DOC-29 and https://example.test/details. ${"More context. ".repeat(90)}`
const parsedResult = {
  design_doc: { id: 20, doc_ref: "DOC-20", title: "Target Graphs", visibility: "public", state: "draft" },
  doc_ref: "DOC-20",
  thread: {
    id: 41,
    state: "open",
    anchor: { start_offset: 18, end_offset: 42, selected_markdown: "The **target graph** maps JOB-42." },
    comments: [
      { id: 4, body: "Earlier" },
      { id: 5, body: longBody }
    ]
  },
  comment: { id: 5, author_kind: "agent", author: { id: 7, name: "Syrus Agent", email_address: "agent@example.test" }, body: longBody },
  version: { id: 9, version_number: 3 },
  mutation_mode: "comment_only"
}

describe("comment_on_design_doc tool card", () => {
  it("registers catalog examples for success, error, and pending states", () => {
    expect(commentOnDesignDocToolCard.toolName).toBe("comment_on_design_doc")
    expect(examples.map((example) => example.id)).toEqual(["anchored_comment", "permission_error", "pending_comment"])
  })

  it("renders markdown, selection, anchor, author, reply, thread, version, and mutation metadata", () => {
    render(<>{commentOnDesignDocToolCard.renderExpanded(context({ input: { doc_ref: "DOC-20", start_offset: 18, end_offset: 42 }, parsedResult }))}</>)

    expect(commentOnDesignDocToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("Replied on DOC-20")
    expect(screen.getByText("Reply")).toBeInTheDocument()
    expect(screen.getByText("v3")).toBeInTheDocument()
    expect(screen.getByText("comment only")).toBeInTheDocument()
    expect(screen.getByText("Syrus Agent · agent")).toBeInTheDocument()
    expect(screen.getByText("18–42")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Thread #41" })).toHaveAttribute("href", "/design_docs/20#thread-41")
    expect(screen.getByText("DOC-20").closest("a")).toHaveAttribute("href", "/design_docs/20#thread-41")
    expect(screen.getByText("target graph").tagName).toBe("STRONG")
    expect(screen.getAllByRole("button", { name: "Show more" })).toHaveLength(1)

    fireEvent.click(screen.getByRole("button", { name: "Show more" }))
    const dialog = within(screen.getByRole("dialog", { name: "Full comment" }))
    expect(dialog.getByText(/More context/)).toBeInTheDocument()
    expect(dialog.getByRole("link", { name: "https://example.test/details" })).toHaveAttribute("href", "https://example.test/details")
  })

  it.each([
    ["direct", parsedResult],
    ["structured content", { structured_content: parsedResult, content: [] }],
    ["text content", { content: [{ type: "text", text: JSON.stringify(parsedResult) }], structured_content: null }]
  ])("renders a %s provider envelope after shared normalization", (_name, envelope) => {
    const normalized = normalizedToolCardParsedResult(envelope)
    render(<>{commentOnDesignDocToolCard.renderExpanded(context({ parsedResult: normalized }))}</>)
    expect(screen.getByRole("link", { name: "Thread #41" })).toBeInTheDocument()
  })

  it("uses a styled error card for permission and anchor failures", () => {
    const { rerender } = render(
      <>
        {commentOnDesignDocToolCard.renderExpanded(
          context({ input: { doc_ref: "DOC-20" }, resultBody: "not allowed to comment on DOC-20", resultError: true })
        )}
      </>
    )
    expect(screen.getByRole("alert")).toHaveTextContent("not allowed")
    expect(commentOnDesignDocToolCard.collapsedSummary?.(context({ input: { doc_ref: "DOC-20" }, resultBody: "anchor not found", resultError: true }))).toBe(
      "Could not comment on DOC-20"
    )

    rerender(<>{commentOnDesignDocToolCard.renderExpanded(context({ parsedResult: { error: "anchor not found" }, resultError: true }))}</>)
    expect(screen.getByRole("alert")).toHaveTextContent("anchor not found")
  })

  it("renders pending and blank-body empty states", () => {
    const { rerender } = render(<>{commentOnDesignDocToolCard.renderExpanded(context({ input: { doc_ref: "DOC-20" }, resultBody: "", parsedResult: null }))}</>)
    expect(screen.getByText("Waiting for the tool result.")).toBeInTheDocument()
    expect(commentOnDesignDocToolCard.collapsedSummary?.(context({ input: { doc_ref: "DOC-20" }, resultBody: "", parsedResult: null }))).toBe(
      "Commenting on DOC-20"
    )

    rerender(
      <>
        {commentOnDesignDocToolCard.renderExpanded(
          context({
            parsedResult: {
              ...parsedResult,
              thread: { ...parsedResult.thread, comments: [parsedResult.comment] },
              comment: { ...parsedResult.comment, body: " " }
            }
          })
        )}
      </>
    )
    expect(screen.getByText("The comment body is blank.")).toBeInTheDocument()
    expect(
      commentOnDesignDocToolCard.collapsedSummary?.(
        context({ parsedResult: { ...parsedResult, thread: { ...parsedResult.thread, comments: [parsedResult.comment] } } })
      )
    ).toBe("Commented on DOC-20")
  })

  it("falls back for malformed payloads", () => {
    expect(commentOnDesignDocToolCard.renderExpanded(context({ parsedResult: { design_doc: parsedResult.design_doc } }))).toBeNull()
    expect(commentOnDesignDocToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
