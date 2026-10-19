import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import { normalizedToolCardParsedResult, normalizedToolName } from "../toolRendering"
import proposeJobToolCard from "./propose_job"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return { toolName: "propose_job", resultBody: "", resultError: false, parsedResult: null, ...overrides }
}

describe("propose_job tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(proposeJobToolCard.toolName).toBe("propose_job")
  })

  it("summarizes a freshly proposed Job", () => {
    const parsedResult = { slug: "fix-output", title: "Fix output", kind: "job", state: "proposed" }
    expect(proposeJobToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("Job proposal: Fix output (proposed)")
  })

  it("renders the same card from a provider-prefixed name and Codex content envelope", () => {
    const payload = { slug: "fix-envelope", title: "Fix envelope", body: "Envelope body", kind: "job", state: "proposed" }
    const envelope = { content: [{ type: "text", text: JSON.stringify(payload) }] }
    const normalizedContext = context({
      toolName: normalizedToolName("mcp__syrus-chat-sidecar__propose_job"),
      parsedResult: normalizedToolCardParsedResult(envelope)
    })

    expect(normalizedContext.toolName).toBe("propose_job")
    render(<>{proposeJobToolCard.renderExpanded(normalizedContext)}</>)
    expect(screen.getByText("Fix envelope")).toBeInTheDocument()
    expect(screen.getByText("Envelope body")).toBeInTheDocument()
  })

  it("renders the slug, state, repository, dependencies, and target epic", () => {
    const parsedResult = {
      slug: "fix-output",
      title: "Fix output",
      kind: "job",
      state: "proposed",
      repository: "tkadauke/syrus",
      dependencies: ["other-proposal"],
      target_epic: { id: 12, number: 292, label: "the pending-action tool-card work" }
    }

    render(<>{proposeJobToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByRole("button", { name: "Copy fix-output to clipboard" })).toBeInTheDocument()
    expect(screen.getByText("Fix output")).toBeInTheDocument()
    expect(screen.getByText("proposed")).toBeInTheDocument()
    expect(screen.getByText("tkadauke/syrus")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Copy tkadauke/syrus to clipboard" })).toBeInTheDocument()
    expect(screen.getByText("Proposal dependencies")).toBeInTheDocument()
    expect(screen.getByText("other-proposal")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "the pending-action tool-card work" })).toHaveAttribute("href", "/epics/12")
  })

  it("renders planned execution capabilities", () => {
    const parsedResult = {
      slug: "fix-output",
      title: "Fix output",
      kind: "job",
      state: "proposed",
      planned_execution: { capabilities: { os: ["linux"], arch: ["x86_64"] }, source: "operator" }
    }

    render(<>{proposeJobToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("Capabilities")).toBeInTheDocument()
    expect(screen.getByText("os: linux · arch: x86_64")).toBeInTheDocument()
  })

  it("renders markdown, labels, linked dependencies, routing, investigation, and provenance", () => {
    const parsedResult = {
      slug: "investigate-output",
      title: "Investigate output",
      body: "Check **rendering** for JOB-18 and https://example.test/evidence.",
      kind: "job",
      state: "proposed",
      labels: ["frontend", "bug"],
      depends_on_job_ids: [18],
      depends_on_epic_ids: [7],
      dependency_requirements: [{ job_id: 18, satisfaction_mode: "deployment_stage", required_deployment_stage_name: "production" }],
      route_to_backlog: true,
      initial_job_state: "backlog",
      investigation: true,
      provider_setting: "muse",
      goal_provenance: { chat_goal_id: 9 }
    }

    render(<>{proposeJobToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("rendering").tagName).toBe("STRONG")
    expect(screen.getAllByRole("link", { name: "JOB-18" })[0]).toHaveAttribute("href", "/jobs/18")
    expect(screen.getByRole("link", { name: "EPIC-7" })).toHaveAttribute("href", "/epics/7")
    expect(screen.getByRole("link", { name: "https://example.test/evidence" })).toHaveAttribute("href", "https://example.test/evidence")
    expect(screen.getByText("frontend")).toBeInTheDocument()
    expect(screen.getByText("bug")).toBeInTheDocument()
    expect(screen.getByText("Investigation")).toBeInTheDocument()
    expect(screen.getByText("backlog")).toBeInTheDocument()
    expect(screen.getByText("muse")).toBeInTheDocument()
    expect(screen.getByText(/chat goal id: 9/)).toBeInTheDocument()
    expect(screen.getByText(/deployment stage: production/)).toBeInTheDocument()
  })

  it("renders input-only target, provider, placement, and media through shared thumbnails", () => {
    const parsedResult = { slug: "fix-output", title: "Fix output", kind: "job", state: "proposed", body: "" }
    const input = {
      epic_id: 29,
      provider: "codex",
      planned_execution: { project_label: "Web", target_label: "//:frontend", capabilities: { os: ["linux"] } },
      media: ["chat_image:77", "snapshot:42"]
    }

    render(<>{proposeJobToolCard.renderExpanded(context({ parsedResult, input }))}</>)

    expect(screen.getByText("No description provided.")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "EPIC-29" })).toHaveAttribute("href", "/epics/29")
    expect(screen.getByText("codex")).toBeInTheDocument()
    expect(screen.getByText(/project label: Web/)).toBeInTheDocument()
    expect(screen.getByText("os: linux")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Open chat_image:77" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Open snapshot:42" })).toBeInTheDocument()
  })

  it("wraps long proposal titles inside the card instead of expanding the chat viewport", () => {
    const parsedResult = {
      slug: "job-ha-webhook-now-playing-updates",
      title: "HA webhook: Now Playing updates + playback state + browser deep link to a very specific integration surface",
      kind: "job",
      state: "proposed"
    }

    render(<>{proposeJobToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText(parsedResult.title)).toHaveClass("min-w-0", "break-words")
  })

  it("renders the materialized Job once confirmed", () => {
    const parsedResult = {
      slug: "fix-output",
      title: "Fix output",
      kind: "job",
      state: "confirmed",
      materialized: { kind: "job", job_id: 4222, job_title: "Fix output", job_state: "running" }
    }

    render(<>{proposeJobToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("confirmed")).toBeInTheDocument()
    const jobLink = screen.getByRole("link", { name: "JOB-4222" })
    expect(jobLink).toHaveAttribute("href", "/jobs/4222")
    expect(jobLink.closest("span")?.parentElement?.parentElement).toHaveTextContent("Fix output")
    expect(screen.getByText("running")).toBeInTheDocument()
  })

  it("renders a withdrawn proposal without a materialized result", () => {
    const parsedResult = { slug: "fix-output", title: "Fix output", kind: "job", state: "withdrawn" }

    render(<>{proposeJobToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("withdrawn")).toBeInTheDocument()
    expect(screen.queryByText(/Materialized as/)).not.toBeInTheDocument()
  })

  it("renders the rejection reason for a rejected proposal", () => {
    const parsedResult = { slug: "fix-output", title: "Fix output", kind: "job", state: "rejected", materialized: { kind: "rejected", reason: "rejected" } }

    render(<>{proposeJobToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("Rejected: rejected")).toBeInTheDocument()
  })

  it("falls back to null for a malformed payload", () => {
    const parsedResult = { oops: true }
    expect(proposeJobToolCard.collapsedSummary?.(context({ parsedResult }))).toBeNull()
    expect(proposeJobToolCard.renderExpanded(context({ parsedResult }))).toBeNull()
  })

  it("falls back to null for a non-object payload", () => {
    const parsedResult = "not json"
    expect(proposeJobToolCard.collapsedSummary?.(context({ parsedResult }))).toBeNull()
    expect(proposeJobToolCard.renderExpanded(context({ parsedResult }))).toBeNull()
  })
})
