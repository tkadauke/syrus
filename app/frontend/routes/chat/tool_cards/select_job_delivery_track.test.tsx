import { render, screen } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import { normalizedToolCardParsedResult, normalizedToolName } from "../toolRendering"
import selectJobDeliveryTrackToolCard, { examples } from "./select_job_delivery_track"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return { toolName: "select_job_delivery_track", resultBody: "", resultError: false, parsedResult: null, ...overrides }
}

function normalizedContext(toolName: string, result: unknown, input: Record<string, unknown> = {}, resultError = false): ToolCardContext {
  return context({
    toolName: normalizedToolName(toolName),
    input,
    resultBody: JSON.stringify(result),
    resultError,
    parsedResult: normalizedToolCardParsedResult(result)
  })
}

function renderCard(cardContext: ToolCardContext) {
  return render(<MemoryRouter>{selectJobDeliveryTrackToolCard.renderExpanded(cardContext)}</MemoryRouter>)
}

describe("select_job_delivery_track tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(selectJobDeliveryTrackToolCard.toolName).toBe("select_job_delivery_track")
  })

  it("summarizes the before/after track change", () => {
    const parsedResult = { job_id: 4225, previous_delivery_track: null, delivery_track: "staging", resolved_delivery_track: "staging" }
    expect(selectJobDeliveryTrackToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("JOB-4225: Default (not stored) → staging")
  })

  it("renders a cleared track distinctly from its resolved default and links the Job", () => {
    const parsedResult = { job_id: 4225, previous_delivery_track: "staging", delivery_track: null, resolved_delivery_track: "default" }
    renderCard(context({ input: { job_id: 4225, track: "" }, parsedResult }))

    expect(screen.getByRole("link", { name: "JOB-4225" })).toHaveAttribute("href", "/jobs/4225")
    expect(screen.getByText("Clear to default")).toBeInTheDocument()
    expect(screen.getByText("staging")).toBeInTheDocument()
    expect(screen.getByText("Default (not stored)")).toBeInTheDocument()
    expect(screen.getByText("default")).toBeInTheDocument()
  })

  it("shows an unconfigured requested and stored name alongside its resolved fallback", () => {
    const parsedResult = { job_id: 4225, previous_delivery_track: "staging", delivery_track: "canary", resolved_delivery_track: "default" }
    renderCard(context({ input: { job_id: 4225, track: "canary" }, parsedResult }))

    expect(screen.getAllByText("canary")).toHaveLength(2)
    expect(screen.getByText("default")).toBeInTheDocument()
  })

  it("uses shared normalizers for an mcp-prefixed text-content envelope", () => {
    const payload = {
      content: [
        { type: "text", text: JSON.stringify({ job_id: 4225, previous_delivery_track: null, delivery_track: "staging", resolved_delivery_track: "staging" }) }
      ]
    }
    const cardContext = normalizedContext("mcp__syrus-chat-sidecar__select_job_delivery_track", payload, { job_id: 4225, track: "staging" })

    expect(cardContext.toolName).toBe("select_job_delivery_track")
    expect(selectJobDeliveryTrackToolCard.collapsedSummary?.(cardContext)).toContain("→ staging")
    renderCard(cardContext)
    expect(screen.getAllByText("staging")).toHaveLength(3)
  })

  it("uses the shared structured-content normalization", () => {
    const payload = {
      content: [{ type: "text", text: "ignored fallback" }],
      structured_content: { job_id: 4225, previous_delivery_track: "staging", delivery_track: "canary", resolved_delivery_track: "default" }
    }
    const cardContext = normalizedContext("select_job_delivery_track", payload, { job_id: 4225, track: "canary" })

    renderCard(cardContext)
    expect(screen.getAllByText("canary")).toHaveLength(2)
    expect(screen.getByText("default")).toBeInTheDocument()
  })

  it("renders an explicit error state", () => {
    const cardContext = context({ input: { job_id: 4225, track: "staging" }, resultBody: "Error: job is not open", resultError: true })

    expect(selectJobDeliveryTrackToolCard.collapsedSummary?.(cardContext)).toBe("Delivery track selection failed: Error: job is not open")
    renderCard(cardContext)
    expect(screen.getByText("Delivery track selection failed")).toBeInTheDocument()
    expect(screen.getByText("Error: job is not open")).toBeInTheDocument()
    expect(screen.getByText("Set delivery track to staging for JOB-4225")).toBeInTheDocument()
  })

  it("falls back to null for a malformed payload", () => {
    expect(selectJobDeliveryTrackToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(selectJobDeliveryTrackToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })

  it("includes catalog examples for configured, cleared, fallback, and error states", () => {
    expect(examples.map((example) => example.id)).toEqual(["configured_track", "cleared_to_default", "unconfigured_fallback", "closed_job_error"])
  })
})
