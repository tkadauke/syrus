import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import { normalizedToolCardParsedResult, normalizedToolName } from "../toolRendering"
import proposeEpicWithJobsToolCard from "./propose_epic_with_jobs"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return { toolName: "propose_epic_with_jobs", resultBody: "", resultError: false, parsedResult: null, ...overrides }
}

describe("propose_epic_with_jobs tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(proposeEpicWithJobsToolCard.toolName).toBe("propose_epic_with_jobs")
  })

  it("summarizes the epic slug, state, and bundled Job count", () => {
    const parsedResult = {
      slug: "tier-2-cards",
      state: "proposed",
      kind: "epic",
      child_jobs: [
        { slug: "core-proposal-cards", state: "proposed" },
        { slug: "core-schedule-cards", state: "proposed" }
      ]
    }

    expect(proposeEpicWithJobsToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("Epic proposal: tier-2-cards (proposed, 2 Jobs)")
  })

  it("renders the target epic, dependency count, and each bundled child proposal", () => {
    const parsedResult = {
      slug: "tier-2-cards",
      state: "confirmed",
      kind: "epic",
      target_epic: { id: 292, number: 292, label: "the pending-action tool-card work" },
      depends_on_proposal_slugs: ["prep-work"],
      child_jobs: [
        { slug: "core-proposal-cards", state: "confirmed", target_repo: "tkadauke/syrus" },
        { slug: "core-schedule-cards", state: "proposed", target_repo: "tkadauke/syrus" }
      ]
    }

    render(<>{proposeEpicWithJobsToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByRole("link", { name: "the pending-action tool-card work" })).toHaveAttribute("href", "/epics/292")
    expect(screen.getByRole("button", { name: "Copy prep-work to clipboard" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Copy core-proposal-cards to clipboard" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Copy core-schedule-cards to clipboard" })).toBeInTheDocument()
    expect(screen.getAllByText("confirmed").length).toBeGreaterThan(0)
    expect(screen.getByText("proposed")).toBeInTheDocument()
  })

  it("merges rich input fields with result state and links every dependency type", () => {
    const input = {
      epic: { slug: "rich-epic", title: "A rich Epic", description: "Epic **Markdown**", target_repo: "tkadauke/syrus", depends_on: ["epic:12"] },
      jobs: [
        {
          slug: "rich-child",
          title: "A rich child",
          description: `${"Long **Markdown** description. ".repeat(40)} https://example.test`,
          target_repo: "tkadauke/syrus",
          provider: "muse",
          depends_on: ["sibling-proposal"],
          depends_on_job_ids: [49],
          depends_on_epic_ids: [8],
          dependency_requirements: [{ job_id: 49, satisfaction_mode: "deployment_stage", required_deployment_stage_name: "production" }],
          media: ["chat_image:7"],
          planned_execution: { project_label: "repo", capabilities: { os: ["linux"], arch: ["arm64"] }, source: "operator" }
        }
      ]
    }
    const parsedResult = {
      slug: "rich-epic",
      state: "confirmed",
      goal_provenance: { chat_goal_id: 6 },
      child_jobs: [{ id: 90, slug: "rich-child", state: "confirmed", target_repo: "tkadauke/syrus", job_id: 501, job_title: "Materialized title" }]
    }

    render(<>{proposeEpicWithJobsToolCard.renderExpanded(context({ input, parsedResult }))}</>)

    expect(screen.getByText("A rich Epic")).toBeInTheDocument()
    expect(screen.getAllByText("Markdown", { selector: "strong" }).length).toBeGreaterThan(0)
    expect(screen.getByText("A rich child")).toBeInTheDocument()
    expect(screen.getAllByRole("link", { name: "tkadauke/syrus" }).length).toBeGreaterThan(0)
    expect(screen.getByRole("button", { name: "Copy sibling-proposal to clipboard" })).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "JOB-49" })).toHaveAttribute("href", "/jobs/49")
    expect(screen.getByRole("link", { name: "EPIC-8" })).toHaveAttribute("href", "/epics/8")
    expect(screen.getByText("JOB-49: deployment stage: production")).toBeInTheDocument()
    expect(screen.getByText("muse")).toBeInTheDocument()
    expect(screen.getByText("os: linux")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Open chat image" })).toBeInTheDocument()
    expect(screen.getByText(/Materialized as/)).toHaveTextContent("Materialized as JOB-501 — Materialized title")
    expect(screen.getAllByRole("button", { name: "Show more" })).not.toHaveLength(0)
  })

  it("renders provider-shaped MCP envelopes after shared normalization", () => {
    const payload = { slug: "enveloped", state: "proposed", child_jobs: [{ slug: "one", state: "proposed" }] }
    const envelopes = [{ structured_content: payload }, { content: [{ type: "text", text: JSON.stringify(payload) }] }]

    envelopes.forEach((envelope) => {
      expect(normalizedToolName("mcp__syrus-chat-sidecar__propose_epic_with_jobs")).toBe("propose_epic_with_jobs")
      expect(proposeEpicWithJobsToolCard.collapsedSummary?.(context({ parsedResult: normalizedToolCardParsedResult(envelope) }))).toBe(
        "Epic proposal: enveloped (proposed, 1 Job)"
      )
    })
  })

  it("renders pending and empty child states", () => {
    render(
      <>
        {proposeEpicWithJobsToolCard.renderExpanded(
          context({
            parsedResult: { slug: "empty", state: "proposed", child_jobs: [] },
            livePendingAction: { state: "pending" } as ToolCardContext["livePendingAction"]
          })
        )}
      </>
    )
    expect(screen.getByText("pending")).toBeInTheDocument()
    expect(screen.getByText("No child Job proposals were returned.")).toBeInTheDocument()
    expect(screen.getByText("No description provided.")).toBeInTheDocument()
  })

  it("falls back to null for a malformed payload", () => {
    const parsedResult = { oops: true }
    expect(proposeEpicWithJobsToolCard.collapsedSummary?.(context({ parsedResult }))).toBeNull()
    expect(proposeEpicWithJobsToolCard.renderExpanded(context({ parsedResult }))).toBeNull()
  })

  it("falls back to null for a non-object payload", () => {
    const parsedResult = "not json"
    expect(proposeEpicWithJobsToolCard.collapsedSummary?.(context({ parsedResult }))).toBeNull()
    expect(proposeEpicWithJobsToolCard.renderExpanded(context({ parsedResult }))).toBeNull()
  })
})
