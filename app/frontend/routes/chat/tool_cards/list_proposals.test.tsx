import { fireEvent, render, screen } from "@testing-library/react"
import { describe, expect, it, vi } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import { normalizedToolCardParsedResult } from "../toolRendering"
import listProposalsToolCard from "./list_proposals"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return { toolName: "list_proposals", resultBody: "", resultError: false, parsedResult: null, ...overrides }
}

describe("list_proposals tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(listProposalsToolCard.toolName).toBe("list_proposals")
  })

  it("summarizes the proposal count", () => {
    const parsedResult = { proposals: [{ slug: "a", state: "proposed", kind: "job" }, { slug: "b", state: "confirmed", kind: "epic" }] }
    expect(listProposalsToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("2 proposals")
  })

  it("renders a friendly empty state for a well-formed empty list", () => {
    const parsedResult = { proposals: [] }
    expect(listProposalsToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("0 proposals")

    render(<>{listProposalsToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("No proposals in this chat yet.")).toBeInTheDocument()
  })

  it("renders complete stacked proposal details with linked entities and markdown", () => {
    const parsedResult = {
      proposals: [
        {
          slug: "fix-output",
          title: "Fix output",
          body: "Read **the notes** at https://example.com and JOB-12.",
          kind: "job",
          state: "pending",
          repository: "tkadauke/syrus",
          dependencies: ["card-primitives"],
          depends_on_job_ids: [12],
          depends_on_epic_ids: [7],
          target_epic: { id: 9, label: "Chat polish" },
          materialized: { kind: "job", job_id: 91, job_title: "Fix output", job_state: "queued" }
        },
        {
          slug: "tier-2-cards",
          title: "Tier 2 Custom Tool Cards",
          body: "",
          kind: "epic",
          state: "withdrawn",
          materialized: { kind: "epic", epic_id: 22, child_jobs: [{ job_id: 92, title: "First card" }] }
        }
      ]
    }

    render(<>{listProposalsToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.queryByRole("table")).not.toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Copy fix-output to clipboard" })).toBeInTheDocument()
    expect(screen.getByText("Fix output")).toBeInTheDocument()
    expect(screen.getByText("pending")).toBeInTheDocument()
    expect(screen.getByText("the notes").tagName).toBe("STRONG")
    expect(screen.getByRole("link", { name: "https://example.com" })).toHaveAttribute("href", "https://example.com")
    expect(screen.getAllByRole("link", { name: "JOB-12" }).length).toBeGreaterThan(0)
    expect(screen.getByRole("link", { name: "EPIC-7" })).toHaveAttribute("href", "/epics/7")
    expect(screen.getByRole("link", { name: "Chat polish" })).toHaveAttribute("href", "/epics/9")
    expect(screen.getByRole("link", { name: "JOB-91" })).toHaveAttribute("href", "/jobs/91")
    expect(screen.getByRole("button", { name: "Copy tier-2-cards to clipboard" })).toBeInTheDocument()
    expect(screen.getByText("Tier 2 Custom Tool Cards")).toBeInTheDocument()
    expect(screen.getByText("withdrawn")).toBeInTheDocument()
    expect(screen.getByText("No description provided.")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "EPIC-22" })).toHaveAttribute("href", "/epics/22")
    expect(screen.getByRole("link", { name: "JOB-92" })).toHaveAttribute("href", "/jobs/92")
  })

  it("passes markdown link clicks through the tool-card context", () => {
    const onLinkClick = vi.fn((_: string, event: React.MouseEvent<HTMLAnchorElement>) => event.preventDefault())
    const parsedResult = { proposals: [{ slug: "linked", state: "proposed", kind: "job", body: "Open https://example.com/notes." }] }

    render(<>{listProposalsToolCard.renderExpanded(context({ parsedResult, onLinkClick }))}</>)
    fireEvent.click(screen.getByRole("link", { name: "https://example.com/notes" }))

    expect(onLinkClick).toHaveBeenCalledWith("https://example.com/notes", expect.anything())
  })

  it("accepts normalized structured-content and text MCP envelopes", () => {
    const payload = { proposals: [{ slug: "wrapped", title: "Wrapped", state: "proposed", kind: "job" }] }
    const envelopes = [
      { structured_content: payload },
      { content: [{ type: "text", text: JSON.stringify(payload) }] }
    ]

    for (const envelope of envelopes) {
      const parsedResult = normalizedToolCardParsedResult(envelope)
      expect(listProposalsToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("1 proposal")
    }
  })

  it("renders structured error results", () => {
    const resultBody = "Error: proposals unavailable"
    render(<>{listProposalsToolCard.renderExpanded(context({ resultBody, resultError: true }))}</>)

    expect(screen.getByText("Proposal list failed")).toBeInTheDocument()
    expect(screen.getByText("Error: proposals unavailable")).toBeInTheDocument()
  })

  it("falls back to null for a malformed payload", () => {
    const parsedResult = { oops: true }
    expect(listProposalsToolCard.collapsedSummary?.(context({ parsedResult }))).toBeNull()
    expect(listProposalsToolCard.renderExpanded(context({ parsedResult }))).toBeNull()
  })

  it("falls back to null for a non-object payload", () => {
    const parsedResult = "not json"
    expect(listProposalsToolCard.collapsedSummary?.(context({ parsedResult }))).toBeNull()
    expect(listProposalsToolCard.renderExpanded(context({ parsedResult }))).toBeNull()
  })
})
