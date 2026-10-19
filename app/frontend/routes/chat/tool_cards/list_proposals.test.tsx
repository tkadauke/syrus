import { fireEvent, render, screen } from "@testing-library/react"
import { describe, expect, it, vi } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import { normalizedToolCardParsedResult, normalizedToolName } from "../toolRendering"
import listProposalsToolCard from "./list_proposals"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return { toolName: "list_proposals", resultBody: "", resultError: false, parsedResult: null, ...overrides }
}

describe("list_proposals tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(listProposalsToolCard.toolName).toBe("list_proposals")
  })

  it("summarizes the proposal count", () => {
    const parsedResult = {
      proposals: [
        { slug: "a", state: "proposed", kind: "job" },
        { slug: "b", state: "confirmed", kind: "epic" }
      ]
    }
    expect(listProposalsToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("2 proposals")
  })

  it("renders a friendly empty state for a well-formed empty list", () => {
    const parsedResult = { proposals: [] }
    expect(listProposalsToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("0 proposals")

    render(<>{listProposalsToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("No proposals in this chat yet.")).toBeInTheDocument()
  })

  it("renders complete wrapping proposal rows with markdown and linked relationships", () => {
    const parsedResult = {
      proposals: [
        {
          slug: "fix-output",
          title: "Fix output",
          body: `Use **shared markdown**. ${"Long body content. ".repeat(80)} https://example.test/spec`,
          kind: "job",
          state: "confirmed",
          repository: "tkadauke/syrus",
          dependencies: ["markdown-preview"],
          depends_on_job_ids: [7554],
          depends_on_epic_ids: [12],
          target_epic: { id: 44, label: "Chat cards" },
          materialized: { kind: "job", job_id: 7734, job_title: "Fix output", job_state: "queued" }
        },
        { slug: "tier-2-cards", title: "Tier 2 Custom Tool Cards", body: "", kind: "epic", state: "withdrawn" }
      ]
    }

    render(<>{listProposalsToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByTestId("proposal-list")).toHaveClass("sm:grid-cols-2")
    expect(screen.getByRole("button", { name: "Copy fix-output to clipboard" })).toBeInTheDocument()
    expect(screen.getByText("Fix output")).toBeInTheDocument()
    expect(screen.getByText("confirmed")).toBeInTheDocument()
    expect(screen.getByText("tkadauke/syrus")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Copy markdown-preview to clipboard" })).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "JOB-7554" })).toHaveAttribute("href", "/jobs/7554")
    expect(screen.getByRole("link", { name: "EPIC-12" })).toHaveAttribute("href", "/epics/12")
    expect(screen.getByRole("link", { name: "Chat cards" })).toHaveAttribute("href", "/epics/44")
    expect(screen.getByRole("link", { name: "JOB-7734" })).toHaveAttribute("href", "/jobs/7734")
    expect(screen.getByRole("button", { name: "Show more" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Copy tier-2-cards to clipboard" })).toBeInTheDocument()
    expect(screen.getByText("Tier 2 Custom Tool Cards")).toBeInTheDocument()
    expect(screen.getByText("withdrawn")).toBeInTheDocument()
    expect(screen.getByText("No description provided.")).toBeInTheDocument()
  })

  it("normalizes provider-prefixed names and differently shaped MCP envelopes", () => {
    const onLinkClick = vi.fn()
    const payload = {
      proposals: [
        {
          slug: "wrapped",
          title: "Wrapped response",
          body: "See https://example.test/details and JOB-42.",
          kind: "job",
          state: "proposed",
          repository: { slug: "acme/widgets" },
          depends_on_proposal_slugs: ["first-step"],
          target_epic_id: 9,
          materialized: { kind: "epic", epic_id: 10, child_jobs: [{ job_id: 11, title: "Child" }] }
        }
      ]
    }
    const parsedResult = normalizedToolCardParsedResult({ content: [{ type: "text", text: JSON.stringify(payload) }] })
    const normalizedContext = context({ toolName: normalizedToolName("mcp__syrus-chat-sidecar__list_proposals"), parsedResult, onLinkClick })

    expect(normalizedContext.toolName).toBe("list_proposals")
    render(<>{listProposalsToolCard.renderExpanded(normalizedContext)}</>)

    expect(screen.getByText("acme/widgets")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Copy first-step to clipboard" })).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "EPIC-9" })).toHaveAttribute("href", "/epics/9")
    expect(screen.getByRole("link", { name: "EPIC-10" })).toHaveAttribute("href", "/epics/10")
    expect(screen.getByRole("link", { name: "JOB-11" })).toHaveAttribute("href", "/jobs/11")
    const url = screen.getByRole("link", { name: "https://example.test/details" })
    fireEvent.click(url)
    expect(onLinkClick).toHaveBeenCalledWith("https://example.test/details", expect.any(Object))
    expect(screen.getByTestId("markdown-preview-content")).toHaveTextContent("JOB-42")
  })

  it("renders pending and error states", () => {
    const pending = context()
    expect(listProposalsToolCard.collapsedSummary?.(pending)).toBe("Loading proposals")
    render(<>{listProposalsToolCard.renderExpanded(pending)}</>)
    expect(screen.getByText("Loading proposals…")).toBeInTheDocument()

    const failed = context({ resultError: true, resultBody: "Error: unavailable" })
    expect(listProposalsToolCard.collapsedSummary?.(failed)).toBe("Proposal list failed")
    render(<>{listProposalsToolCard.renderExpanded(failed)}</>)
    expect(screen.getByText("Error: unavailable")).toBeInTheDocument()
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
