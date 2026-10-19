import { fireEvent, render, screen, within } from "@testing-library/react"
import { beforeEach, describe, expect, it, vi } from "vitest"
import { pluginToolCardRendererFor, type ToolCardContext } from "@app/pluginToolCards"
import listInsightsToolCard from "./list_insights"
import readInsightToolCard from "./read_insight"
import retireInsightToolCard from "./retire_insight"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "list_insights",
    resultBody: "{}",
    resultError: false,
    parsedResult: {},
    ...overrides
  }
}

const baseInsight = {
  id: 41,
  title: "Prepare failures cluster",
  summary: "Several prepare failures share the same Bundler setup issue.",
  category: "repeated_failure",
  severity: "high",
  confidence: 0.92,
  state: "pending",
  proposal_type: "create_job",
  repository: { id: 3, slug: "acme/widgets" },
  job: { id: 200, slug: "JOB-200", title: "Insight analysis", path: "/jobs/200" },
  source_workflow: { id: 12, slug: "WF-12", path: "/jobs/200?tab=workflows#workflow-12" },
  source_run: { id: 99, slug: "RUN-99", path: "/admin/runs/99/transcript" },
  created_at: "2026-09-09T10:00:00Z",
  updated_at: "2026-09-09T11:00:00Z"
}

describe("Agent Insights tool cards", () => {
  beforeEach(() => {
    Object.assign(navigator, {
      clipboard: { writeText: vi.fn().mockResolvedValue(undefined) }
    })
  })

  it("registers plugin-local card modules for Agent Insights tools", () => {
    expect(pluginToolCardRendererFor("list_insights")).not.toBeNull()
    expect(pluginToolCardRendererFor("read_insight")).not.toBeNull()
    expect(pluginToolCardRendererFor("retire_insight")).not.toBeNull()
  })

  it("renders an empty list without falling back to raw JSON", () => {
    const cardContext = context({ parsedResult: { insights: [] } })

    expect(listInsightsToolCard.collapsedSummary?.(cardContext)).toBe("0 insights")
    render(<>{listInsightsToolCard.renderExpanded(cardContext)}</>)

    expect(screen.getByText("No insights match this query.")).toBeInTheDocument()
  })

  it("renders pending, accepted, and retired insights with summaries, metadata, and source links", () => {
    const insights = [
      baseInsight,
      { ...baseInsight, id: 42, title: "Resolved memory cleanup", state: "accepted", severity: "medium" },
      { ...baseInsight, id: 43, title: "Retired duplicate", state: "retired", severity: "low" }
    ]

    render(<>{listInsightsToolCard.renderExpanded(context({ parsedResult: { insights } }))}</>)

    expect(screen.getAllByText("Prepare failures cluster")).toHaveLength(2)
    expect(screen.getAllByText("Several prepare failures share the same Bundler setup issue.")).toHaveLength(6)
    expect(screen.getAllByText("Resolved memory cleanup")).toHaveLength(2)
    expect(screen.getAllByText("Retired duplicate")).toHaveLength(2)
    expect(screen.getAllByText("pending")).toHaveLength(2)
    expect(screen.getAllByText("accepted")).toHaveLength(2)
    expect(screen.getAllByText("retired")).toHaveLength(2)
    expect(screen.getAllByText("acme/widgets")).toHaveLength(6)
    expect(screen.getAllByRole("link", { name: "WF-12" })[0]).toHaveAttribute("href", "/jobs/200?tab=workflows#workflow-12")
    expect(screen.getAllByRole("link", { name: "RUN-99" })[0]).toHaveAttribute("href", "/admin/runs/99/transcript")
    fireEvent.click(screen.getAllByRole("button", { name: "Copy INSIGHT-41 to clipboard" })[0])
    expect(navigator.clipboard.writeText).toHaveBeenCalledWith("INSIGHT-41")
    expect(screen.getAllByRole("link", { name: "INSIGHT-41" })[0]).toHaveAttribute("href", "/s/INSIGHT-41")
    expect(screen.getAllByText("Prepare failures cluster")[0].closest(".sm\\:hidden")).not.toBeNull()
  })

  it("renders read_insight details with long evidence, recommended action, links, and retirement outcome", () => {
    const longPrompt = Array.from({ length: 8 }, (_, index) => `Step ${index + 1}: inspect the workflow evidence carefully.`).join("\n")
    const evidence = Array.from({ length: 7 }, (_, index) => ({
      job_id: 50 + index,
      run_id: 70 + index,
      kind: `prepare_failure_${index}`,
      job_path: `/jobs/${50 + index}`,
      run_transcript_path: `/admin/runs/${70 + index}/transcript`
    }))
    const cardContext = context({
      toolName: "read_insight",
      parsedResult: {
        insight: {
          ...baseInsight,
          evidence,
          suggested_prompt: longPrompt,
          retired_reason: "Fixed by follow-up work.",
          retired_at: "2026-09-10T09:00:00Z",
          superseded_by_job_id: 77
        }
      }
    })

    expect(readInsightToolCard.collapsedSummary?.(cardContext)).toBe("Prepare failures cluster (pending)")
    render(<>{readInsightToolCard.renderExpanded(cardContext)}</>)

    expect(screen.getByText("Recommended action")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Show more" })).toBeInTheDocument()
    expect(screen.getByText("Show remaining evidence (2)")).toBeInTheDocument()
    expect(screen.getByText("Retirement outcome")).toBeInTheDocument()
    expect(screen.getByText("Superseded by")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "JOB-77" })).toHaveAttribute("href", "/jobs/77")
    expect(screen.getByRole("link", { name: "JOB-50" })).toHaveAttribute("href", "/jobs/50")
    expect(screen.getByRole("link", { name: "RUN-70" })).toHaveAttribute("href", "/admin/runs/70/transcript")
    fireEvent.click(screen.getByRole("button", { name: "Copy RUN-70 to clipboard" }))
    expect(navigator.clipboard.writeText).toHaveBeenCalledWith("RUN-70")
  })

  it("renders retire_insight outcome details from the text response and call input", () => {
    const cardContext = context({
      toolName: "retire_insight",
      resultBody: "Suggestion #41 retired.",
      input: {
        target_insight_id: 41,
        reason: "Duplicate of the newer insight.",
        superseded_by_insight_id: 44,
        superseded_by_job_id: 82
      },
      parsedResult: null
    })

    expect(retireInsightToolCard.collapsedSummary?.(cardContext)).toBe("Retired insight #41")
    render(<>{retireInsightToolCard.renderExpanded(cardContext)}</>)

    expect(screen.getByText("Suggestion #41 retired.")).toBeInTheDocument()
    expect(screen.getByText("Duplicate of the newer insight.")).toBeInTheDocument()
    expect(screen.getByText("INSIGHT-44")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "JOB-82" })).toHaveAttribute("href", "/jobs/82")
  })

  it("renders the structured result returned by insight mutation tools", () => {
    const cardContext = context({
      toolName: "retire_insight",
      resultBody: JSON.stringify({ message: "Retired 2 insights.", insight_ids: [41, 42] }),
      parsedResult: { message: "Retired 2 insights.", insight_ids: [41, 42] },
      input: { insight_ids: [41, 42], reason: "Both findings are stale." }
    })

    expect(retireInsightToolCard.collapsedSummary?.(cardContext)).toBe("Retired insight #41")
    render(<>{retireInsightToolCard.renderExpanded(cardContext)}</>)
    expect(screen.getByText("Retired 2 insights.")).toBeInTheDocument()
    expect(screen.getByText("Both findings are stale.")).toBeInTheDocument()
  })

  it("renders the live pending-action state on shared outcome cards", () => {
    const cardContext = context({
      toolName: "retire_insight",
      parsedResult: { message: "Retirement requested.", insight_ids: [41] },
      livePendingAction: {
        id: 9,
        action: "retire_insight",
        state: "confirmed",
        label: "Retire insight",
        detail: "Retirement was confirmed by the operator.",
        app_confirm_path: "/confirm",
        app_reject_path: "/reject"
      }
    })

    render(<>{retireInsightToolCard.renderExpanded(cardContext)}</>)
    expect(screen.getByText("confirmed")).toBeInTheDocument()
    expect(screen.getByText("Retirement requested.")).toBeInTheDocument()
    expect(screen.getByText("Retirement was confirmed by the operator.")).toBeInTheDocument()
  })

  it("falls back to the generic renderer for malformed list and detail payloads", () => {
    expect(listInsightsToolCard.renderExpanded(context({ parsedResult: { insights: "oops" } }))).toBeNull()
    expect(readInsightToolCard.renderExpanded(context({ toolName: "read_insight", parsedResult: { insight: { id: 5 } } }))).toBeNull()
  })

  it("ignores malformed insight rows while preserving valid rows", () => {
    render(<>{listInsightsToolCard.renderExpanded(context({ parsedResult: { insights: [{ oops: true }, baseInsight] } }))}</>)

    const rows = screen.getAllByRole("row")
    expect(rows).toHaveLength(2)
    expect(within(rows[1]).getByText("Prepare failures cluster")).toBeInTheDocument()
  })

  it("normalizes Codex and structured-content envelopes and renders markdown links", () => {
    const codexEnvelope = {
      content: [{ type: "text", text: JSON.stringify({ insights: [{ ...baseInsight, summary: "See **JOB-200** at https://example.test/details." }] }) }]
    }
    const structuredEnvelope = { structured_content: { insights: [{ ...baseInsight, id: 42, title: "Structured insight" }] } }

    render(<>{listInsightsToolCard.renderExpanded(context({ parsedResult: codexEnvelope }))}</>)
    expect(screen.getAllByRole("link", { name: "https://example.test/details" })[0]).toHaveAttribute("href", "https://example.test/details")
    expect(listInsightsToolCard.collapsedSummary?.(context({ parsedResult: structuredEnvelope }))).toBe("1 insight")
  })

  it("shows all list filters in the empty state and renders tool failures", () => {
    const filtered = context({ input: { state: "pending", repository_id: 3, limit: 10, page: 2 }, parsedResult: { insights: [] } })
    render(<>{listInsightsToolCard.renderExpanded(filtered)}</>)

    expect(screen.getByText("State: pending")).toBeInTheDocument()
    expect(screen.getByText("Repository: 3")).toBeInTheDocument()
    expect(screen.getByText("Limit: 10")).toBeInTheDocument()
    expect(screen.getByText("Page: 2")).toBeInTheDocument()
    expect(screen.getByText(/No insights match: State: pending/)).toBeInTheDocument()

    const { unmount } = render(<>{listInsightsToolCard.renderExpanded(context({ resultError: true, resultBody: "Repository unavailable" }))}</>)
    expect(screen.getByText("Repository unavailable")).toBeInTheDocument()
    unmount()
  })
})
