import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import { normalizedToolCardParsedResult, normalizedToolName } from "../toolRendering"
import listDeliveryTracksToolCard from "./list_delivery_tracks"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return { toolName: "list_delivery_tracks", resultBody: "", resultError: false, parsedResult: null, ...overrides }
}

const payload = {
  repository: "tkadauke/syrus",
  tracks: [
    {
      name: "default",
      default: true,
      branch: "develop",
      review_grade_phase: "review",
      landing_grade_phase: "landing",
      ci_failure_grade_phase: "ci_failure",
      branch_health_grade_phase: "branch_health"
    },
    { name: "hotfix", default: false, branch: "main", review_grade_phase: null, landing_grade_phase: null, after_landing_sync_to: "default" }
  ]
}

describe("list_delivery_tracks tool card", () => {
  it("registers under the exact MCP tool name and accepts an mcp__-prefixed name", () => {
    expect(listDeliveryTracksToolCard.toolName).toBe("list_delivery_tracks")
    expect(normalizedToolName("mcp__syrus-chat-sidecar__list_delivery_tracks")).toBe(listDeliveryTracksToolCard.toolName)
  })

  it("summarizes the collapsed row with a track count", () => {
    expect(listDeliveryTracksToolCard.collapsedSummary?.(context({ parsedResult: payload }))).toBe("2 delivery tracks")
  })

  it.each([
    ["content text", { content: [{ type: "text", text: JSON.stringify(payload) }], structured_content: null }],
    ["structured content", { content: [{ type: "text", text: "ignored" }], structured_content: payload }]
  ])("renders the shared %s envelope normalization", (_label, envelope) => {
    const parsedResult = normalizedToolCardParsedResult(envelope)
    render(<>{listDeliveryTracksToolCard.renderExpanded(context({ parsedResult }))}</>)
    expect(screen.getByRole("link", { name: "tkadauke/syrus" })).toHaveAttribute("href", "https://github.com/tkadauke/syrus")
    expect(screen.getByRole("link", { name: "develop" })).toHaveAttribute("href", "https://github.com/tkadauke/syrus/tree/develop")
  })

  it("renders an empty state when no tracks are configured", () => {
    render(<>{listDeliveryTracksToolCard.renderExpanded(context({ parsedResult: { repository: "tkadauke/syrus", tracks: [] } }))}</>)
    expect(screen.getByText("No delivery tracks configured.")).toBeInTheDocument()
  })

  it("renders all phases, branch links, and resolves an after-landing track to its branch", () => {
    render(<>{listDeliveryTracksToolCard.renderExpanded(context({ parsedResult: payload }))}</>)

    expect(screen.getAllByText("default")).toHaveLength(3)
    expect(screen.getByText("hotfix")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "tkadauke/syrus" })).toHaveAttribute("href", "https://github.com/tkadauke/syrus")
    expect(screen.getByRole("link", { name: "main" })).toHaveAttribute("href", "https://github.com/tkadauke/syrus/tree/main")
    expect(screen.getByRole("link", { name: "default" })).toHaveAttribute("href", "https://github.com/tkadauke/syrus/tree/develop")
    expect(screen.queryByRole("link", { name: "default" })).not.toHaveAttribute("href", "https://github.com/tkadauke/syrus/tree/default")
    expect(screen.getByText("review")).toBeInTheDocument()
    expect(screen.getByText("landing")).toBeInTheDocument()
    expect(screen.getByText("ci_failure")).toBeInTheDocument()
    expect(screen.getByText("branch_health")).toBeInTheDocument()
  })

  it("renders an unknown after-landing track as plain text", () => {
    const parsedResult = { repository: "tkadauke/syrus", tracks: [{ name: "hotfix", default: false, branch: "main", after_landing_sync_to: "missing" }] }
    render(<>{listDeliveryTracksToolCard.renderExpanded(context({ parsedResult }))}</>)
    expect(screen.getByText("missing")).toBeInTheDocument()
    expect(screen.queryByRole("link", { name: "missing" })).not.toBeInTheDocument()
  })

  it("falls back to generic rendering for errors and malformed results", () => {
    expect(listDeliveryTracksToolCard.collapsedSummary?.(context({ resultError: true, parsedResult: payload }))).toBeNull()
    expect(listDeliveryTracksToolCard.renderExpanded(context({ resultError: true, parsedResult: payload }))).toBeNull()
    expect(listDeliveryTracksToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(listDeliveryTracksToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
