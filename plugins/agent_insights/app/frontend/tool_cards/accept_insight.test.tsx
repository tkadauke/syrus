import { fireEvent, render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ChatPendingActionInline } from "@app/api/chats"
import type { ToolCardContext } from "@app/pluginToolCards"
import acceptInsightToolCard from "./accept_insight"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return { toolName: "accept_insight", resultBody: "{}", resultError: false, parsedResult: {}, ...overrides }
}

function live(state: ChatPendingActionInline["state"]): ChatPendingActionInline {
  return { id: 92, action: "accept_insights", state, label: "Accept insights", detail: null, app_confirm_path: "/confirm", app_reject_path: "/reject" }
}

describe("accept_insight tool card", () => {
  it("renders every immediate result and input field with linked references and markdown", () => {
    const cardContext = context({
      input: { insight_id: 41 },
      parsedResult: {
        message: "Accepted **INSIGHT-41**. See https://example.test/details.",
        insight_ids: [41],
        states: { 41: "accepted" },
        proposal_types: { 41: "create_job" },
        job_ids: [7761],
        memory_ids: [162]
      }
    })
    expect(acceptInsightToolCard.collapsedSummary?.(cardContext)).toBe("Accepted 1 insight")
    const { container } = render(<>{acceptInsightToolCard.renderExpanded(cardContext)}</>)

    expect(screen.getByText("INSIGHT-41", { selector: "strong" })).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "https://example.test/details" })).toHaveAttribute("href", "https://example.test/details")
    expect(screen.getAllByRole("link", { name: "INSIGHT-41" })).toHaveLength(2)
    expect(screen.getByText("INSIGHT-41: accepted")).toBeInTheDocument()
    expect(screen.getByText("INSIGHT-41: create job")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "JOB-7761" })).toHaveAttribute("href", "/jobs/7761")
    expect(screen.getByRole("link", { name: "MEMORY-162" })).toHaveAttribute("href", "/memories")
    expect(container.querySelector(".flex.min-w-0.flex-wrap")).not.toBeNull()
  })

  it("renders a bulk request as pending with its intended transition", () => {
    const cardContext = context({
      input: { insight_ids: [41, 42] },
      parsedResult: {
        pending_action_id: 92,
        message: "Accept these?",
        insight_ids: [41, 42],
        proposal_types: { 41: "create_job", 42: "save_memory" },
        intended_transition: "accept_insights"
      }
    })
    expect(acceptInsightToolCard.collapsedSummary?.(cardContext)).toBe("Accept requested · 2 insights · pending")
    render(<>{acceptInsightToolCard.renderExpanded(cardContext)}</>)
    expect(screen.getByText("pending")).toBeInTheDocument()
    expect(screen.getByText("#92")).toBeInTheDocument()
    expect(screen.getByText("accept insights")).toBeInTheDocument()
    expect(screen.getByText("INSIGHT-42: save memory")).toBeInTheDocument()
  })

  it.each<ChatPendingActionInline["state"]>(["confirmed", "rejected"])("prefers a matching live %s state", (state) => {
    const cardContext = context({
      input: { insight_ids: [41, 42] },
      parsedResult: { pending_action_id: 92, insight_ids: [41, 42], message: "Accept these?" },
      livePendingAction: live(state)
    })
    expect(acceptInsightToolCard.collapsedSummary?.(cardContext)).toContain(state)
    render(<>{acceptInsightToolCard.renderExpanded(cardContext)}</>)
    expect(screen.getByText(state)).toBeInTheDocument()
    expect(screen.queryByText("pending")).not.toBeInTheDocument()
  })

  it("renders a styled error with the attempted input preserved by raw details", () => {
    const cardContext = context({ input: { insight_id: 41 }, resultError: true, resultBody: "Insight is already accepted.", parsedResult: null })
    expect(acceptInsightToolCard.collapsedSummary?.(cardContext)).toBe("Insight acceptance failed")
    render(<>{acceptInsightToolCard.renderExpanded(cardContext)}</>)
    expect(screen.getByText("failed")).toBeInTheDocument()
    expect(screen.getByText("Insight is already accepted.")).toHaveClass("text-danger-text")
  })

  it.each([
    ["structured content", { structured_content: { message: "Done.", insight_ids: [41] } }],
    ["Codex content envelope", { content: [{ type: "text", text: JSON.stringify({ message: "Done.", insight_ids: [41] }) }] }],
    ["data envelope", { data: { message: "Done.", insight_ids: [41] } }]
  ])("normalizes the %s result shape", (_label, parsedResult) => {
    expect(acceptInsightToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("Accepted 1 insight")
  })

  it("shows empty states and expands a long markdown message", () => {
    const message = Array.from({ length: 20 }, (_, index) => `Line ${index}: **acceptance detail**`).join("\n")
    const { rerender } = render(<>{acceptInsightToolCard.renderExpanded(context({ parsedResult: { message } }))}</>)
    fireEvent.click(screen.getByRole("button", { name: "Show more" }))
    expect(screen.getByRole("dialog", { name: "Acceptance message" })).toBeInTheDocument()

    rerender(<>{acceptInsightToolCard.renderExpanded(context({ parsedResult: { message: "" } }))}</>)
    expect(screen.getByText("No result message was provided.")).toBeInTheDocument()
    expect(screen.getByText("No acceptance details were returned.")).toBeInTheDocument()
  })

  it("falls back to generic rendering for malformed payloads", () => {
    expect(acceptInsightToolCard.renderExpanded(context({ parsedResult: { unrelated: true } }))).toBeNull()
  })
})
