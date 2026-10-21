import { fireEvent, render, screen, within } from "@testing-library/react"
import { beforeEach, describe, expect, it, vi } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import dismissInsightToolCard, { examples } from "./dismiss_insight"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "dismiss_insight",
    input: {},
    resultBody: "{}",
    resultError: false,
    parsedResult: {},
    ...overrides
  }
}

function renderCard(cardContext: ToolCardContext) {
  return render(<>{dismissInsightToolCard.renderExpanded(cardContext)}</>)
}

describe("dismiss_insight tool card", () => {
  beforeEach(() => {
    Object.assign(navigator, { clipboard: { writeText: vi.fn().mockResolvedValue(undefined) } })
  })

  it("renders the single result, linked input/result ids, states, message, and markdown reason", () => {
    const reason = `Duplicate reported by JOB-39 (**verified**); see https://example.test/evidence. ${"Additional audit context. ".repeat(30)}`
    const cardContext = context({
      input: { insight_id: 41, reason },
      parsedResult: { message: "Dismissed insight #41.", insight_ids: [41], states: { 41: "dismissed" } }
    })

    expect(dismissInsightToolCard.collapsedSummary?.(cardContext)).toBe("Dismissed INSIGHT-41")
    renderCard(cardContext)

    expect(screen.getByText("Dismissed insight #41.")).toBeInTheDocument()
    expect(screen.getByText("Requested insights")).toBeInTheDocument()
    expect(screen.getByText("Result insights")).toBeInTheDocument()
    expect(screen.getByText("Result states")).toBeInTheDocument()
    expect(screen.getAllByRole("link", { name: "INSIGHT-41" })).toHaveLength(3)
    expect(screen.getAllByRole("link", { name: "INSIGHT-41" })[0]).toHaveAttribute("href", "/s/INSIGHT-41")
    expect(screen.getByTestId("markdown-preview-content")).toHaveTextContent("JOB-39")
    expect(screen.getByRole("link", { name: "https://example.test/evidence" })).toHaveAttribute("href", "https://example.test/evidence")
    expect(screen.getByText("dismissed")).toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Show more" }))
    expect(screen.getByRole("dialog")).toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: "Copy Show more" }))
    expect(navigator.clipboard.writeText).toHaveBeenCalledWith(reason)
  })

  it("renders a bulk pending request and follows confirmed and rejected live states", () => {
    const pending = context({
      input: { insight_ids: [41, 42], reason: "Both findings are stale." },
      parsedResult: {
        pending_action_id: 701,
        state: "pending",
        message: "Dismiss insights #41, #42?",
        insight_ids: [41, 42],
        intended_transition: "dismiss_insights"
      }
    })

    expect(dismissInsightToolCard.collapsedSummary?.(pending)).toBe("Dismiss 2 insights · pending confirmation")
    const { rerender } = renderCard(pending)
    expect(screen.getByText("#701")).toBeInTheDocument()
    expect(screen.getByText("dismiss insights")).toBeInTheDocument()
    expect(screen.getByText("pending")).toBeInTheDocument()
    expect(screen.getAllByRole("link", { name: "INSIGHT-41" }).length).toBeGreaterThan(0)
    expect(screen.getAllByRole("link", { name: "INSIGHT-42" }).length).toBeGreaterThan(0)

    const confirmed: ToolCardContext = {
      ...pending,
      livePendingAction: {
        id: 701,
        action: "dismiss_insights",
        state: "confirmed",
        label: "Dismiss 2 insights",
        detail: "Confirmed by the operator.",
        app_confirm_path: "/confirm",
        app_reject_path: "/reject"
      }
    }
    expect(dismissInsightToolCard.collapsedSummary?.(confirmed)).toBe("Dismiss 2 insights · confirmed")
    rerender(<>{dismissInsightToolCard.renderExpanded(confirmed)}</>)
    expect(screen.getByText("confirmed")).toBeInTheDocument()
    expect(screen.getByText("Confirmed by the operator.")).toBeInTheDocument()

    const rejected: ToolCardContext = {
      ...confirmed,
      livePendingAction: { ...confirmed.livePendingAction!, state: "rejected", detail: "Rejected by the operator." }
    }
    expect(dismissInsightToolCard.collapsedSummary?.(rejected)).toBe("Dismiss 2 insights · rejected")
    rerender(<>{dismissInsightToolCard.renderExpanded(rejected)}</>)
    expect(screen.getByText("rejected")).toBeInTheDocument()
    expect(screen.getByText("Rejected by the operator.")).toBeInTheDocument()
  })

  it("normalizes structured, content-text, and data envelopes", () => {
    const payload = { message: "Dismissed both insights.", insight_ids: [51, 52], states: { 51: "dismissed", 52: "dismissed" } }
    const envelopes = [{ structured_content: payload }, { content: [{ type: "text", text: JSON.stringify(payload) }] }, { data: payload }]

    for (const parsedResult of envelopes) {
      const cardContext = context({ input: { insight_ids: [51, 52], reason: "Duplicates." }, parsedResult })
      expect(dismissInsightToolCard.collapsedSummary?.(cardContext)).toBe("Dismissed 2 insights")
      const view = renderCard(cardContext)
      expect(screen.getByText("Dismissed both insights.")).toBeInTheDocument()
      view.unmount()
    }
  })

  it("renders styled errors and an explicit empty result state", () => {
    const error = context({
      input: { insight_id: 41, reason: "Stale." },
      resultError: true,
      resultBody: JSON.stringify({ error: "Insight #41 is no longer pending." }),
      parsedResult: { error: "Insight #41 is no longer pending." }
    })
    expect(dismissInsightToolCard.collapsedSummary?.(error)).toBe("Dismiss insight failed")
    const view = renderCard(error)
    expect(screen.getByText("failed")).toBeInTheDocument()
    expect(screen.getByText("Insight #41 is no longer pending.")).toHaveClass("text-danger-text")
    view.unmount()

    renderCard(context({ input: { insight_id: 44, reason: "" }, parsedResult: {} }))
    expect(screen.getByText("No result message was returned.")).toBeInTheDocument()
    expect(screen.getByText("No reason supplied.")).toBeInTheDocument()
  })

  it("uses wrapping layouts and exposes catalog examples for success, pending, and error states", () => {
    renderCard(
      context({
        input: { insight_ids: [1, 2], reason: "Duplicate." },
        parsedResult: { message: "Dismissed.", insight_ids: [1, 2], states: { 1: "dismissed", 2: "dismissed" } }
      })
    )

    const states = screen.getByText("Result states").parentElement
    expect(within(states!).getByText("INSIGHT-1").closest("div")).toHaveClass("flex-wrap")
    expect(screen.getByText("Requested insights").parentElement?.parentElement).toHaveClass("sm:grid-cols-2")
    expect(examples.map((example) => example.id)).toEqual(["single_dismissed", "bulk_pending", "dismiss_error"])
  })
})
