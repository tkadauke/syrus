import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import selectJobDeliveryTrackToolCard from "./select_job_delivery_track"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return { toolName: "select_job_delivery_track", resultBody: "", resultError: false, parsedResult: null, ...overrides }
}

describe("select_job_delivery_track tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(selectJobDeliveryTrackToolCard.toolName).toBe("select_job_delivery_track")
  })

  it("summarizes the before/after track change", () => {
    const parsedResult = { job_id: 4225, previous_delivery_track: null, delivery_track: "staging", resolved_delivery_track: "staging" }
    expect(selectJobDeliveryTrackToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("JOB-4225: default → staging")
  })

  it("renders previous, new, and resolved tracks", () => {
    const parsedResult = { job_id: 4225, previous_delivery_track: "staging", delivery_track: null, resolved_delivery_track: "default" }
    render(<>{selectJobDeliveryTrackToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("JOB-4225")).toBeInTheDocument()
    expect(screen.getByText("staging")).toBeInTheDocument()
    expect(screen.getAllByText("default")).toHaveLength(2)
  })

  it("falls back to null for a malformed payload", () => {
    expect(selectJobDeliveryTrackToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(selectJobDeliveryTrackToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
