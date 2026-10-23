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

  it("renders titles, markdown, dependencies, execution, media, and a materialized child", () => {
    const parsedResult = {
      id: 10,
      slug: "tier-2-cards",
      title: "Tier 2 cards",
      description: "Build **complete** proposal cards.",
      state: "confirmed",
      kind: "epic",
      target_epic: { id: 292, number: 292, label: "the pending-action tool-card work" },
      depends_on: ["prep-work", "epic:8"],
      depends_on_job_ids: [15],
      child_jobs: [
        {
          id: 11,
          slug: "core-proposal-cards",
          title: "Core proposal cards",
          description: "Render JOB-12 and https://example.test/spec.",
          state: "confirmed",
          target_repo: "tkadauke/syrus",
          depends_on_job_ids: [12],
          dependency_requirements: [{ job_id: 12, satisfaction_mode: "deployment_stage", required_deployment_stage_name: "staging" }],
          planned_execution: { target_label: "//:test", capabilities: { os: ["linux"] } },
          provider: "codex",
          media: ["chat_image:42"],
          media_previews: [
            {
              id: "chat_image:42",
              kind: "chat_image",
              filename: "layout.png",
              content_type: "image/png",
              file_path: "/api/v1/app/chats/5/media/chat_images/42/file"
            }
          ],
          materialized: { kind: "job", job_id: 99, job_title: "Core proposal cards", job_state: "running" }
        },
        {
          id: 13,
          slug: "core-schedule-cards",
          title: "Schedule cards",
          description: "",
          state: "proposed",
          target_repo: "tkadauke/syrus",
          depends_on: ["core-proposal-cards"]
        }
      ]
    }

    render(<>{proposeEpicWithJobsToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByRole("link", { name: "the pending-action tool-card work" })).toHaveAttribute("href", "/epics/292")
    expect(screen.getByText("Tier 2 cards")).toBeInTheDocument()
    expect(screen.getByText("complete").tagName).toBe("STRONG")
    expect(screen.getByRole("link", { name: "EPIC-8" })).toHaveAttribute("href", "/epics/8")
    expect(screen.getByRole("link", { name: "JOB-15" })).toHaveAttribute("href", "/jobs/15")
    expect(screen.getAllByRole("link", { name: "JOB-12" }).length).toBeGreaterThan(0)
    expect(screen.getByText("Planned execution").parentElement).toHaveTextContent("target: //:test · os:linux")
    expect(screen.getByText("JOB-12 — deployment stage · stage: staging")).toBeInTheDocument()
    expect(screen.getByRole("img", { name: "layout.png" })).toHaveAttribute("src", "/api/v1/app/chats/5/media/chat_images/42/file")
    expect(screen.getByRole("link", { name: "Core proposal cards" })).toHaveAttribute("href", "/jobs/99")
    expect(screen.getByText("No description provided.")).toBeInTheDocument()
    expect(screen.getAllByRole("button", { name: "Copy core-proposal-cards to clipboard" }).length).toBeGreaterThan(0)
    expect(screen.getByRole("button", { name: "Copy core-schedule-cards to clipboard" })).toBeInTheDocument()
    expect(screen.getAllByText("confirmed").length).toBeGreaterThan(0)
    expect(screen.getByText("proposed")).toBeInTheDocument()
  })

  it("accepts normalized Codex and Claude MCP envelopes", () => {
    const payload = { slug: "portable", title: "Portable", state: "proposed", child_jobs: [] }
    const codex = { structured_content: payload }
    const claude = { content: [{ type: "text", text: JSON.stringify(payload) }] }

    expect(normalizedToolName("mcp__syrus__propose_epic_with_jobs")).toBe("propose_epic_with_jobs")
    expect(proposeEpicWithJobsToolCard.collapsedSummary?.(context({ parsedResult: normalizedToolCardParsedResult(codex) }))).toBe(
      "Epic proposal: Portable (proposed, 0 Jobs)"
    )
    expect(proposeEpicWithJobsToolCard.collapsedSummary?.(context({ parsedResult: normalizedToolCardParsedResult(claude) }))).toBe(
      "Epic proposal: Portable (proposed, 0 Jobs)"
    )
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
