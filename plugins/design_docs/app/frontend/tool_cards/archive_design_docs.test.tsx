import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import archiveDesignDocsToolCard from "./archive_design_docs"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "archive_design_docs",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

function payload(count = 2) {
  const targets = Array.from({ length: count }, (_, index) => ({ doc_ref: `DOC-${index + 1}`, title: `Design ${index + 1}` }))
  return {
    pending_action_group_id: 8,
    pending_action_id: 81,
    state: "pending",
    requested_refs: [...targets.map((target) => target.doc_ref), "DOC-99"],
    eligible_count: count,
    skipped_count: 1,
    member_count: count,
    reason: "The designs have shipped.",
    targets,
    skipped: [{ doc_ref: "DOC-99", title: "Old design", reason: "already archived" }]
  }
}

describe("archive_design_docs tool card", () => {
  it("renders every grouped target, skipped doc, and shared reason", () => {
    render(<>{archiveDesignDocsToolCard.renderExpanded(context({ parsedResult: payload() }))}</>)

    expect(screen.getByRole("link", { name: "DOC-1" })).toHaveAttribute("href", "/design_docs/1")
    expect(screen.getByText(/Design 2/)).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "DOC-99" })).toHaveAttribute("href", "/design_docs/99")
    expect(screen.getByText("already archived")).toBeInTheDocument()
    expect(screen.getAllByText("The designs have shipped.")).toHaveLength(2)
    expect(screen.getByText("2 eligible · 1 skipped")).toBeInTheDocument()
  })

  it("keeps long target lists in a bounded scrolling preview", () => {
    const { container } = render(<>{archiveDesignDocsToolCard.renderExpanded(context({ parsedResult: payload(100) }))}</>)

    expect(screen.getByRole("link", { name: "DOC-100" })).toBeInTheDocument()
    expect(container.querySelector("ul.max-h-56.overflow-y-auto")).toBeInTheDocument()
  })

  it("uses the anchored member's live pending state", () => {
    render(
      <>
        {archiveDesignDocsToolCard.renderExpanded(
          context({
            parsedResult: payload(),
            livePendingAction: { id: 81, state: "confirming", reason: "The designs have shipped." } as ToolCardContext["livePendingAction"]
          })
        )}
      </>
    )

    expect(screen.getByText("confirming")).toBeInTheDocument()
  })

  it("renders an all-skipped result without a pending-action panel", () => {
    const value = payload(0)
    value.pending_action_group_id = null as never
    value.pending_action_id = null as never
    value.state = "skipped"
    value.member_count = 0

    render(<>{archiveDesignDocsToolCard.renderExpanded(context({ parsedResult: value }))}</>)

    expect(screen.getByText("skipped")).toBeInTheDocument()
    expect(screen.getByText("0 eligible · 1 skipped")).toBeInTheDocument()
  })
})
