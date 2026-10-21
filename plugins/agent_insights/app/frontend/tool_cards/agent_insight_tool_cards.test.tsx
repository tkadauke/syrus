import { fireEvent, render, screen, within } from "@testing-library/react"
import { beforeEach, describe, expect, it, vi } from "vitest"
import i18n from "@app/i18n"
import { pluginToolCardRendererFor, type ToolCardContext } from "@app/pluginToolCards"
import listInsightsToolCard from "./list_insights"
import readInsightToolCard from "./read_insight"
import retireInsightToolCard from "./retire_insight"
import submitInsightToolCard from "./submit_insight"
import updateInsightToolCard from "./update_insight"

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

  it("renders an empty list with its applied filter without falling back to raw JSON", () => {
    const cardContext = context({ input: { state: "pending" }, parsedResult: { insights: [] } })

    expect(listInsightsToolCard.collapsedSummary?.(cardContext)).toBe("0 insights")
    render(<>{listInsightsToolCard.renderExpanded(cardContext)}</>)

    expect(screen.getByText("No insights match this query.")).toBeInTheDocument()
    expect(screen.getByText("No insights match: State: pending.")).toBeInTheDocument()
  })

  it("renders pending, accepted, and retired insights with summaries, metadata, and source links", () => {
    const insights = [
      baseInsight,
      { ...baseInsight, id: 42, title: "Resolved memory cleanup", state: "accepted", severity: "medium" },
      { ...baseInsight, id: 43, title: "Retired duplicate", state: "retired", severity: "low" }
    ]

    render(<>{listInsightsToolCard.renderExpanded(context({ parsedResult: { insights } }))}</>)

    expect(screen.getAllByText("Prepare failures cluster")[0]).toBeInTheDocument()
    expect(screen.getAllByText("Several prepare failures share the same Bundler setup issue.")).toHaveLength(6)
    expect(screen.getAllByText("Resolved memory cleanup")[0]).toBeInTheDocument()
    expect(screen.getAllByText("Retired duplicate")[0]).toBeInTheDocument()
    expect(screen.getAllByText("pending")[0]).toBeInTheDocument()
    expect(screen.getAllByText("accepted")[0]).toBeInTheDocument()
    expect(screen.getAllByText("retired")[0]).toBeInTheDocument()
    expect(screen.getAllByText("acme/widgets")).toHaveLength(6)
    expect(screen.getAllByRole("link", { name: "WF-12" })[0]).toHaveAttribute("href", "/jobs/200?tab=workflows#workflow-12")
    expect(screen.getAllByRole("link", { name: "RUN-99" })[0]).toHaveAttribute("href", "/admin/runs/99/transcript")
    fireEvent.click(screen.getAllByRole("button", { name: "Copy INSIGHT-41 to clipboard" })[0])
    expect(navigator.clipboard.writeText).toHaveBeenCalledWith("INSIGHT-41")
    expect(screen.getAllByRole("link", { name: "INSIGHT-41" })[0]).toHaveAttribute("href", "/s/INSIGHT-41")
    const mobileList = screen.getAllByText("Prepare failures cluster")[0].closest(".sm\\:hidden")
    expect(mobileList).not.toBeNull()
    const mobileRow = within(mobileList!.firstElementChild as HTMLElement)
    expect(mobileRow.getByText("repeated failure")).toBeInTheDocument()
    expect(mobileRow.getByText("Job")).toBeInTheDocument()
    expect(mobileRow.getByText("92% confidence")).toBeInTheDocument()
    expect(mobileRow.getByRole("link", { name: "WF-12" })).toHaveAttribute("href", "/jobs/200?tab=workflows#workflow-12")
    expect(mobileRow.getByRole("link", { name: "RUN-99" })).toHaveAttribute("href", "/admin/runs/99/transcript")
    expect(mobileRow.getByRole("link", { name: "acme/widgets" })).toHaveAttribute("href", "/repositories/3")
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
          summary: "Read **JOB-200** at https://example.test/details.",
          memory_suggestion: "Keep **this durable guidance**.",
          target_memory_id: 18,
          stale_memory_text: "The previous memory is *stale*.",
          stale_memory_evidence: "Confirmed by RUN-70.",
          target_insight_id: 40,
          retired_reason: "Fixed by follow-up work.",
          retired_at: "2026-09-10T09:00:00Z",
          superseded_by_job_id: 77
        }
      }
    })

    expect(readInsightToolCard.collapsedSummary?.(cardContext)).toBe("Prepare failures cluster (pending)")
    render(<>{readInsightToolCard.renderExpanded(cardContext)}</>)

    expect(screen.getByText("Recommended action")).toBeInTheDocument()
    expect(screen.getByText("Summary")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "JOB-200" })).toHaveAttribute("href", "/jobs/200")
    expect(screen.getByRole("link", { name: "https://example.test/details" })).toHaveAttribute("href", "https://example.test/details")
    expect(screen.getByText("Memory suggestion")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Copy MEMORY-18 to clipboard" })).toBeInTheDocument()
    expect(screen.getByText("Target insight")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "INSIGHT-40" })).toHaveAttribute("href", "/s/INSIGHT-40")
    expect(screen.getByText("Show more")).toBeInTheDocument()
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
      input: { insight_ids: [41, 42], reason: "Both findings are stale." },
      livePendingAction: {
        id: 7,
        action: "retire_insight",
        state: "confirmed",
        label: "Retire insights",
        detail: "Confirmed by the operator.",
        app_confirm_path: "/confirm",
        app_reject_path: "/reject"
      }
    })

    expect(retireInsightToolCard.collapsedSummary?.(cardContext)).toBe("Retired insight #41")
    render(<>{retireInsightToolCard.renderExpanded(cardContext)}</>)
    expect(screen.getByText("Retired 2 insights.")).toBeInTheDocument()
    expect(screen.getByText("Both findings are stale.")).toBeInTheDocument()
    expect(screen.getByText("Confirmed by the operator.")).toBeInTheDocument()
  })

  it("normalizes wrapped provider envelopes and renders errors", () => {
    const wrapped = { content: [{ type: "text", text: JSON.stringify({ insights: [baseInsight] }) }] }
    expect(listInsightsToolCard.collapsedSummary?.(context({ parsedResult: wrapped }))).toBe("1 insight")
    render(<>{listInsightsToolCard.renderExpanded(context({ resultBody: "Repository is not accessible.", resultError: true }))}</>)
    expect(screen.getByText("Repository is not accessible.")).toBeInTheDocument()
  })

  it("normalizes read_insight provider envelopes and uses structured reference ids without slugs", () => {
    const wrapped = {
      structured_content: {
        data: {
          insight: {
            ...baseInsight,
            job: { id: 200, title: "Insight analysis", path: "/jobs/200" },
            source_workflow: { id: 12, path: "/jobs/200?tab=workflows#workflow-12" },
            source_run: { id: 99, path: "/admin/runs/99/transcript" }
          }
        }
      }
    }
    render(<>{readInsightToolCard.renderExpanded(context({ toolName: "read_insight", parsedResult: wrapped }))}</>)

    expect(screen.getByRole("link", { name: "JOB-200" })).toHaveAttribute("href", "/jobs/200")
    expect(screen.getByRole("link", { name: "WF-12" })).toHaveAttribute("href", "/jobs/200?tab=workflows#workflow-12")
    expect(screen.getByRole("link", { name: "RUN-99" })).toHaveAttribute("href", "/admin/runs/99/transcript")
  })

  it("renders read_insight not-found errors and empty successful results", () => {
    const failed = context({ toolName: "read_insight", resultBody: "Error: insight not found or not accessible: 999", resultError: true })
    expect(readInsightToolCard.collapsedSummary?.(failed)).toBe("Insight lookup failed")
    const { rerender } = render(<>{readInsightToolCard.renderExpanded(failed)}</>)
    expect(screen.getByText("Error: insight not found or not accessible: 999")).toBeInTheDocument()

    rerender(<>{readInsightToolCard.renderExpanded(context({ toolName: "read_insight", resultBody: "", parsedResult: null }))}</>)
    expect(screen.getByText("No insight was returned.")).toBeInTheDocument()
  })

  it("localizes mutation summaries, labels, and fallback messages", async () => {
    await i18n.changeLanguage("de")
    const cardContext = context({ parsedResult: { insight_ids: [41] } })
    expect(submitInsightToolCard.collapsedSummary?.(cardContext)).toBe("Einblick #41 gespeichert")
    expect(updateInsightToolCard.collapsedSummary?.(cardContext)).toBe("Einblick #41 aktualisiert")
    expect(retireInsightToolCard.collapsedSummary?.(cardContext)).toBe("Einblick #41 zurückgezogen")
    render(<>{retireInsightToolCard.renderExpanded(cardContext)}</>)
    expect(screen.getByText("Ergebnis der Zurückziehung")).toBeInTheDocument()
    expect(screen.getByText("Änderung des Einblicks angefordert.")).toBeInTheDocument()
    await i18n.changeLanguage("en")
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
})
