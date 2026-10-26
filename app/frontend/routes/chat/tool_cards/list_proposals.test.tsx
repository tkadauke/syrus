import { fireEvent, render, screen } from "@testing-library/react"
import { describe, expect, it, vi } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import { normalizedToolCardParsedResult, normalizedToolName } from "../toolRendering"
import listProposalsToolCard from "./list_proposals"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: normalizedToolName("mcp__syrus-chat-sidecar__list_proposals"),
    resultBody: "",
    resultError: false,
    resultSettled: true,
    parsedResult: null,
    ...overrides
  }
}

const proposal = {
  slug: "rich-card",
  title: "A deliberately long proposal title that wraps instead of overflowing its card",
  body: `Use **Markdown**, JOB-77, and https://example.test/details. ${"More detail. ".repeat(50)}`,
  kind: "job",
  state: "confirmed",
  repository: { slug: "acme/widget" },
  repository_id: 8,
  dependencies: ["shared-primitives", "shared-primitives"],
  depends_on_proposal_slugs: ["shared-primitives", "release-epic"],
  depends_on_job_ids: [12],
  depends_on_epic_ids: [3],
  dependency_requirements: [
    { job_id: 81, satisfaction_mode: "deployed", required_deployment_stage_name: "production" },
    { proposal_slug: "requirement-proposal", satisfaction_mode: "success" }
  ],
  target_epic: { epic_id: 9, title: "Interface polish" },
  materialized: { kind: "job", job_id: 44, job_title: "Rich card", job_state: "queued" }
}

describe("list_proposals tool card", () => {
  it("registers under the normalized MCP tool name and summarizes the count", () => {
    expect(context().toolName).toBe(listProposalsToolCard.toolName)
    expect(listProposalsToolCard.collapsedSummary?.(context({ parsedResult: { proposals: [proposal] } }))).toBe("1 proposal")
  })

  it.each([
    ["structured content", { structured_content: { proposals: [proposal] } }],
    ["text content", { content: [{ type: "text", text: JSON.stringify({ proposals: [proposal] }) }] }]
  ])("renders all linked fields and expandable Markdown from a normalized %s envelope", (_label, envelope) => {
    const onLinkClick = vi.fn()
    render(<>{listProposalsToolCard.renderExpanded(context({ parsedResult: normalizedToolCardParsedResult(envelope), onLinkClick }))}</>)

    expect(screen.getByText(proposal.title)).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "acme/widget" })).toHaveAttribute("href", "/repositories/8")
    expect(screen.getByRole("link", { name: "JOB-12" })).toHaveAttribute("href", "/jobs/12")
    expect(screen.getByRole("link", { name: "JOB-81" })).toHaveAttribute("href", "/jobs/81")
    expect(screen.getByRole("link", { name: "EPIC-3" })).toHaveAttribute("href", "/epics/3")
    expect(screen.getByRole("link", { name: "EPIC-9" })).toHaveAttribute("href", "/epics/9")
    expect(screen.getByRole("link", { name: "JOB-44" })).toHaveAttribute("href", "/jobs/44")
    expect(screen.getByText("release-epic")).toBeInTheDocument()
    expect(screen.getByText("requirement-proposal")).toBeInTheDocument()
    expect(screen.getByText(/deployed: production/)).toBeInTheDocument()
    expect(screen.getAllByText("shared-primitives")).toHaveLength(1)
    expect(screen.getByRole("button", { name: "Show more" })).toBeInTheDocument()
    fireEvent.click(screen.getByRole("link", { name: "https://example.test/details" }))
    expect(onLinkClick).toHaveBeenCalled()
  })

  it("links materialized Epics and child Jobs", () => {
    render(
      <>
        {listProposalsToolCard.renderExpanded(
          context({
            parsedResult: {
              proposals: [{ ...proposal, slug: "epic", materialized: { kind: "epic", epic_id: 20, child_jobs: [{ job_id: 21, title: "Child" }] } }]
            }
          })
        )}
      </>
    )
    expect(screen.getByRole("link", { name: "EPIC-20" })).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "JOB-21" })).toBeInTheDocument()
  })

  it("renders pending, empty, and error states", () => {
    const { rerender } = render(<>{listProposalsToolCard.renderExpanded(context({ resultSettled: false }))}</>)
    expect(screen.getByText("Loading proposals…")).toBeInTheDocument()
    rerender(<>{listProposalsToolCard.renderExpanded(context({ parsedResult: { proposals: [] } }))}</>)
    expect(screen.getByText("No proposals in this chat yet.")).toBeInTheDocument()
    rerender(<>{listProposalsToolCard.renderExpanded(context({ resultError: true, resultBody: "Provider unavailable" }))}</>)
    expect(screen.getByText("Provider unavailable")).toBeInTheDocument()
  })

  it("falls back to the generic card for malformed payloads", () => {
    expect(listProposalsToolCard.renderExpanded(context({ parsedResult: { oops: true } }))).toBeNull()
  })
})
