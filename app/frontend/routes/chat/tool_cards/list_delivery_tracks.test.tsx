import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import { normalizedToolCardParsedResult, normalizedToolName } from "../toolRendering"
import listDeliveryTracksToolCard, { examples } from "./list_delivery_tracks"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return { toolName: "list_delivery_tracks", resultBody: "", resultError: false, parsedResult: null, ...overrides }
}
const payload = {
  repository: "tkadauke/syrus",
  tracks: [
    {
      name: "default",
      default: true,
      branch: "main",
      review_grade_phase: "review",
      landing_grade_phase: "landing",
      ci_failure_grade_phase: "ci-failure",
      branch_health_grade_phase: "branch-health",
      after_landing_sync_to: "develop"
    },
    { name: "staging", default: false, branch: "release/staging" }
  ]
}

describe("list_delivery_tracks tool card", () => {
  it("registers under the normalized MCP tool name", () => {
    expect(listDeliveryTracksToolCard.toolName).toBe("list_delivery_tracks")
    expect(normalizedToolName("mcp__syrus-chat-sidecar__list_delivery_tracks")).toBe(listDeliveryTracksToolCard.toolName)
  })

  it("summarizes the track count and repository", () => {
    expect(listDeliveryTracksToolCard.collapsedSummary?.(context({ parsedResult: payload }))).toBe("2 delivery tracks · tkadauke/syrus")
  })

  it.each([
    ["content text", { content: [{ type: "text", text: JSON.stringify(payload) }], structured_content: null }],
    ["structured content", { content: [{ type: "text", text: "ignored" }], structured_content: payload }]
  ])("renders a normalized %s envelope", (_label, envelope) => {
    render(<>{listDeliveryTracksToolCard.renderExpanded(context({ parsedResult: normalizedToolCardParsedResult(envelope) }))}</>)
    expect(screen.getByRole("link", { name: "tkadauke/syrus" })).toHaveAttribute("href", "https://github.com/tkadauke/syrus")
    expect(screen.getByRole("link", { name: "main" })).toHaveAttribute("href", "https://github.com/tkadauke/syrus/tree/main")
  })

  it("renders every grade phase, sync target, and responsive cell labels", () => {
    const { container } = render(<>{listDeliveryTracksToolCard.renderExpanded(context({ parsedResult: payload }))}</>)
    expect(screen.getAllByText("default")).toHaveLength(2)
    for (const value of ["review", "landing", "ci-failure", "branch-health"]) expect(screen.getByText(value)).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "develop" })).toHaveAttribute("href", "https://github.com/tkadauke/syrus/tree/develop")
    expect(container.querySelector('[data-label="CI failure phase"]')).toBeInTheDocument()
    expect(container.querySelector('[data-label="Sync after landing"]')).toBeInTheDocument()
  })

  it("renders the linked repository with an empty state", () => {
    const envelope = {
      content: [{ type: "text", text: JSON.stringify({ repository: "tkadauke/syrus", tracks: [] }) }],
      structured_content: null
    }
    render(<>{listDeliveryTracksToolCard.renderExpanded(context({ parsedResult: normalizedToolCardParsedResult(envelope) }))}</>)
    expect(screen.getByRole("link", { name: "tkadauke/syrus" })).toBeInTheDocument()
    expect(screen.getByText("No delivery tracks configured.")).toBeInTheDocument()
  })

  it("falls back to generic rendering for errors and malformed payloads", () => {
    const error = context({ resultError: true, resultBody: "No repository attached." })
    expect(listDeliveryTracksToolCard.collapsedSummary?.(error)).toBeNull()
    expect(listDeliveryTracksToolCard.renderExpanded(error)).toBeNull()
    expect(listDeliveryTracksToolCard.renderExpanded(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(listDeliveryTracksToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })

  it("provides catalog examples for populated, empty, and error results", () => {
    expect(examples.map((example) => example.id)).toEqual(["multiple_tracks", "empty", "error"])
  })
})
