import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import { normalizedToolCardParsedResult, normalizedToolName } from "../toolRendering"
import proposeEpicToolCard from "./propose_epic"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return { toolName: "propose_epic", resultBody: "", resultError: false, parsedResult: null, ...overrides }
}

describe("propose_epic tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(proposeEpicToolCard.toolName).toBe("propose_epic")
  })

  it("summarizes a proposed Epic", () => {
    const parsedResult = { slug: "tier-2-cards", title: "Tier 2 Custom Tool Cards", kind: "epic", state: "proposed" }
    expect(proposeEpicToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("Epic proposal: Tier 2 Custom Tool Cards (proposed)")
  })

  it("renders the materialized Epic and each linked child Job once confirmed", () => {
    const parsedResult = {
      slug: "tier-2-cards",
      title: "Tier 2 Custom Tool Cards",
      kind: "epic",
      state: "confirmed",
      materialized: { kind: "epic", epic_id: 292, epic_title: "Tier 2 Custom Tool Cards", child_jobs: [{ job_id: 4222, title: "Add core cards" }] }
    }

    render(<>{proposeEpicToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByRole("link", { name: "EPIC-292" })).toHaveAttribute("href", "/epics/292")
    expect(screen.getByText("Child Jobs (1)")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "JOB-4222" })).toHaveAttribute("href", "/jobs/4222")
    expect(screen.getByText("Add core cards")).toBeInTheDocument()
  })

  it("renders shared proposal fields and an empty description state", () => {
    const parsedResult = {
      slug: "tier-2-cards",
      title: "Tier 2 Custom Tool Cards",
      body: "",
      kind: "epic",
      state: "proposed",
      labels: ["frontend"],
      repository: "tkadauke/syrus",
      depends_on_job_ids: [18],
      depends_on_epic_ids: [7]
    }

    render(<>{proposeEpicToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("No description provided.")).toBeInTheDocument()
    expect(screen.getByText("frontend")).toBeInTheDocument()
    expect(screen.getByText("tkadauke/syrus")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "JOB-18" })).toHaveAttribute("href", "/jobs/18")
    expect(screen.getByRole("link", { name: "EPIC-7" })).toHaveAttribute("href", "/epics/7")
  })

  it("renders a deprecated-tool rejection from a Claude-style error envelope", () => {
    const parsedResult = {
      content: [{ type: "text", text: "Error: propose_epic is deprecated. Call propose_epic_with_jobs instead." }]
    }

    render(<>{proposeEpicToolCard.renderExpanded(context({ parsedResult, input: { title: "Card overhaul" } }))}</>)

    expect(screen.getByText("Epic proposal failed")).toBeInTheDocument()
    expect(screen.getAllByText(/propose_epic is deprecated/).length).toBeGreaterThan(0)
    expect(screen.getByText(/Use propose_epic_with_jobs/)).toBeInTheDocument()
  })

  it("normalizes a provider-prefixed name and Codex structured-content envelope", () => {
    const payload = {
      slug: "tier-2-cards",
      title: "Tier 2 Cards",
      body: "See https://example.test/spec.",
      kind: "epic",
      state: "proposed",
      depends_on_job_ids: [18]
    }
    const normalizedContext = context({
      toolName: normalizedToolName("mcp__syrus-chat-sidecar__propose_epic"),
      parsedResult: normalizedToolCardParsedResult({ structured_content: payload })
    })

    expect(normalizedContext.toolName).toBe("propose_epic")
    render(<>{proposeEpicToolCard.renderExpanded(normalizedContext)}</>)
    expect(screen.getByRole("link", { name: "JOB-18" })).toHaveAttribute("href", "/jobs/18")
    expect(screen.getByRole("link", { name: "https://example.test/spec" })).toHaveAttribute("href", "https://example.test/spec")
  })

  it("falls back to null for a malformed payload", () => {
    const parsedResult = { oops: true }
    expect(proposeEpicToolCard.collapsedSummary?.(context({ parsedResult }))).toBeNull()
    expect(proposeEpicToolCard.renderExpanded(context({ parsedResult }))).toBeNull()
  })
})
