import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
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

  it("renders a table row per track including grade phases and the default badge", () => {
    const parsedResult = {
      repository: "tkadauke/syrus",
      tracks: [
        { name: "default", default: true, branch: "main", review_grade_phase: "review", landing_grade_phase: "landing" },
        { name: "staging", default: false, branch: "staging-branch", review_grade_phase: null, landing_grade_phase: null }
      ]
    }

    render(<>{listDeliveryTracksToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getAllByText("default")).toHaveLength(2)
    expect(screen.getByText("staging")).toBeInTheDocument()
    expect(screen.getByText("main")).toBeInTheDocument()
    expect(screen.getByText("review")).toBeInTheDocument()
    expect(screen.getByText("landing")).toBeInTheDocument()
  })

  it("falls back to null for a malformed payload", () => {
    expect(listDeliveryTracksToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(listDeliveryTracksToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
