import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import { normalizedToolCardParsedResult, normalizedToolName } from "@app/routes/chat/toolRendering"
import getSpendingToolCard from "./get_spending"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "get_spending",
    input: { window: "30d", repository_id: 8, epic_id: 4 },
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

const result = {
  total_cost_usd: 12.34,
  total_input_tokens: 12500,
  total_output_tokens: 3200,
  top_runs: [
    { job_id: 42, title: "Improve spending reports", cost_usd: 8.25 },
    { job_id: 43, title: "Keep a very long job title contained on narrow screens", cost_usd: 4.09 }
  ],
  by_day: [
    { date: "2026-10-17", cost_usd: 4.09 },
    { date: "2026-10-18", cost_usd: 8.25 }
  ]
}

describe("get_spending tool card", () => {
  it("registers and summarizes the windowed cost", () => {
    expect(getSpendingToolCard.toolName).toBe("get_spending")
    expect(getSpendingToolCard.collapsedSummary?.(context({ parsedResult: result }))).toBe("$12.34 over 30d")
  })

  it.each([
    ["mcp__syrus-chat-sidecar__get_spending", result],
    ["mcp__syrus-chat-deferred-sidecar__get_spending", { structured_content: result }],
    ["syrus-chat-sidecar.get_spending", { content: [{ type: "text", text: JSON.stringify(result) }] }]
  ])("renders identically for %s result envelopes", (rawName, envelope) => {
    const normalizedResult = normalizedToolCardParsedResult(envelope)
    const normalizedContext = context({ toolName: normalizedToolName(rawName), parsedResult: normalizedResult })

    expect(normalizedContext.toolName).toBe("get_spending")
    expect(getSpendingToolCard.collapsedSummary?.(normalizedContext)).toBe("$12.34 over 30d")
  })

  it("renders every result field, scope links, and compact daily bars", () => {
    const { container } = render(<>{getSpendingToolCard.renderExpanded(context({ parsedResult: result }))}</>)

    expect(screen.getByText("30d")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Repository #8" })).toHaveAttribute("href", "/repositories/8")
    expect(screen.getByRole("link", { name: "EPIC-4" })).toHaveAttribute("href", "/epics/4")
    expect(screen.getByText("$12.34")).toBeInTheDocument()
    expect(screen.getByText("12,500")).toBeInTheDocument()
    expect(screen.getByText("3,200")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "JOB-42" })).toHaveAttribute("href", "/jobs/42")
    expect(screen.getByText("Improve spending reports")).toBeInTheDocument()
    expect(screen.getByLabelText("2026-10-18: $8.25")).toBeInTheDocument()
    expect(container.querySelector(".overflow-x-auto")).toBeNull()
  })

  it("uses the default window and renders an empty state", () => {
    render(<>{getSpendingToolCard.renderExpanded(context({ input: {}, parsedResult: { ...result, total_cost_usd: 0, top_runs: [] } }))}</>)
    expect(screen.getByText("30d")).toBeInTheDocument()
    expect(screen.getByText("No spend in window.")).toBeInTheDocument()
  })

  it("renders the invalid-window error state", () => {
    render(<>{getSpendingToolCard.renderExpanded(context({ input: { window: "1d" }, resultError: true, resultBody: "window must be one of 7d, 30d, 90d" }))}</>)
    expect(screen.getByText("Window must be one of 7d, 30d, 90d.")).toBeInTheDocument()
  })

  it("falls back for malformed successful payloads", () => {
    expect(getSpendingToolCard.collapsedSummary?.(context({ parsedResult: { total_cost_usd: 2 } }))).toBeNull()
    expect(getSpendingToolCard.renderExpanded(context({ parsedResult: { total_cost_usd: 2 } }))).toBeNull()
  })
})
