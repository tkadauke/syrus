import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import { normalizedToolCardParsedResult, normalizedToolName } from "../toolRendering"
import listDeliveryTracksToolCard from "./list_delivery_tracks"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return { toolName: "list_delivery_tracks", resultBody: "", resultError: false, parsedResult: null, ...overrides }
}

describe("list_delivery_tracks tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(listDeliveryTracksToolCard.toolName).toBe("list_delivery_tracks")
  })

  it("summarizes the collapsed row with a track count", () => {
    const parsedResult = { repository: "tkadauke/syrus", tracks: [{ name: "default", default: true, branch: "main" }] }
    expect(listDeliveryTracksToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("1 delivery track")
  })

  it("renders an empty state when no tracks are configured", () => {
    render(<>{listDeliveryTracksToolCard.renderExpanded(context({ parsedResult: { repository: "tkadauke/syrus", tracks: [] } }))}</>)
    expect(screen.getByText("No delivery tracks configured.")).toBeInTheDocument()
  })

  it("renders linked repository and branches plus every grade phase", () => {
    const parsedResult = {
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
        {
          name: "hotfix",
          default: false,
          branch: "main",
          review_grade_phase: null,
          landing_grade_phase: null,
          after_landing_sync_to: "default"
        }
      ]
    }

    render(<>{listDeliveryTracksToolCard.renderExpanded(context({ parsedResult }))}</>)

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

  it("uses responsive table rows that stack with labels on mobile", () => {
    const parsedResult = { repository: "tkadauke/syrus", tracks: [{ name: "default", branch: "main" }] }
    const { container } = render(<>{listDeliveryTracksToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(container.querySelector("table")).toHaveClass("block", "sm:table")
    expect(container.querySelector('td[data-label="Branch"]')).toBeInTheDocument()
    expect(screen.getByText("Branch", { selector: "td span" })).toHaveClass("sm:hidden")
  })

  it("renders content text and structured content envelopes through the shared normalizer", () => {
    const payload = { repository: "tkadauke/syrus", tracks: [{ name: "default", branch: "main" }] }
    const textEnvelope = { content: [{ type: "text", text: JSON.stringify(payload) }], structured_content: null }
    const structuredEnvelope = { content: [{ type: "text", text: "ignored" }], structured_content: payload }

    expect(listDeliveryTracksToolCard.collapsedSummary?.(context({ parsedResult: normalizedToolCardParsedResult(textEnvelope) }))).toBe("1 delivery track")
    expect(listDeliveryTracksToolCard.collapsedSummary?.(context({ parsedResult: normalizedToolCardParsedResult(structuredEnvelope) }))).toBe(
      "1 delivery track"
    )
  })

  it("normalizes an MCP-prefixed tool name to this renderer's registration name", () => {
    expect(normalizedToolName("mcp__syrus-chat-sidecar__list_delivery_tracks")).toBe(listDeliveryTracksToolCard.toolName)
  })

  it("falls back to shared error rendering for error results", () => {
    const errorContext = context({ resultError: true, resultBody: "repository not attached", parsedResult: { repository: "secret/repo", tracks: [] } })
    expect(listDeliveryTracksToolCard.collapsedSummary?.(errorContext)).toBeNull()
    expect(listDeliveryTracksToolCard.renderExpanded(errorContext)).toBeNull()
  })

  it("falls back to null for a malformed payload", () => {
    expect(listDeliveryTracksToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(listDeliveryTracksToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
