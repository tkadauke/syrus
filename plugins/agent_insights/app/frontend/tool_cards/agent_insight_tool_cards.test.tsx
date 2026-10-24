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
    expect(screen.getAllByRole("button", { name: "Copy MEMORY-18 to clipboard" })).toHaveLength(2)
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

    expect(retireInsightToolCard.collapsedSummary?.(cardContext)).toBe("Retired 2 insights")
    render(<>{retireInsightToolCard.renderExpanded(cardContext)}</>)
    expect(screen.getByText("Retired 2 insights.")).toBeInTheDocument()
    expect(screen.getByText("Both findings are stale.")).toBeInTheDocument()
    expect(screen.getByText("Confirmed by the operator.")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "INSIGHT-41" })).toHaveAttribute("href", "/s/INSIGHT-41")
    expect(screen.getByRole("link", { name: "INSIGHT-42" })).toHaveAttribute("href", "/s/INSIGHT-42")
  })

  it("renders every bulk retirement field with linked mappings, result references, and markdown", () => {
    const reason = `Superseded by **validated work** in JOB-82 and https://example.test/audit.\n\n${"Long supporting context. ".repeat(40)}`
    const cardContext = context({
      toolName: "retire_insight",
      input: {
        insight_ids: [41, 42],
        reason,
        retire_accepted: true,
        superseded_by_insight_ids: { 41: 44 },
        superseded_by_job_ids: { 42: 82 }
      },
      parsedResult: {
        structured_content: {
          data: {
            message: "Retired 2 insights.",
            insight_ids: [41, 42],
            states: { 41: "retired", 42: "retired" },
            job_ids: [90],
            memory_ids: [12]
          }
        }
      }
    })

    render(<>{retireInsightToolCard.renderExpanded(cardContext)}</>)

    expect(screen.getByText("Accepted insights allowed")).toBeInTheDocument()
    expect(screen.getAllByRole("link", { name: "INSIGHT-41" }).length).toBeGreaterThan(1)
    expect(screen.getByRole("link", { name: "INSIGHT-44" })).toHaveAttribute("href", "/s/INSIGHT-44")
    expect(screen.getByRole("link", { name: "JOB-82" })).toHaveAttribute("href", "/jobs/82")
    expect(screen.getByRole("link", { name: "JOB-90" })).toHaveAttribute("href", "/jobs/90")
    expect(screen.getByText("MEMORY-12")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Copy MEMORY-12 to clipboard" })).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "https://example.test/audit" })).toHaveAttribute("href", "https://example.test/audit")
    expect(screen.getByText("validated work").tagName).toBe("STRONG")
    expect(screen.getByRole("button", { name: "Show more" })).toBeInTheDocument()
  })

  it("uses live pending state for bulk retirement and handles provider text envelopes", () => {
    const cardContext = context({
      toolName: "retire_insight",
      input: { insight_ids: [51, 52], reason: "Duplicate evidence." },
      parsedResult: {
        content: [{ type: "text", text: JSON.stringify({ state: "pending", message: "Retire insights #51, #52?", insight_ids: [51, 52] }) }]
      },
      livePendingAction: {
        id: 9,
        action: "retire_insights",
        state: "rejected",
        label: "Retire 2 insights",
        detail: "Rejected by the operator.",
        app_confirm_path: "/confirm",
        app_reject_path: "/reject"
      }
    })

    render(<>{retireInsightToolCard.renderExpanded(cardContext)}</>)
    expect(screen.getByText("rejected")).toBeInTheDocument()
    expect(screen.getByText("Rejected by the operator.")).toBeInTheDocument()
    expect(screen.queryByText("pending")).not.toBeInTheDocument()
  })

  it("renders retirement failures and empty results explicitly", () => {
    render(
      <>
        {retireInsightToolCard.renderExpanded(
          context({ toolName: "retire_insight", resultBody: "Accepted insight cannot be retired.", resultError: true, parsedResult: null })
        )}
      </>
    )
    expect(screen.getByText("Accepted insight cannot be retired.")).toBeInTheDocument()

    render(<>{retireInsightToolCard.renderExpanded(context({ toolName: "retire_insight", resultBody: "", parsedResult: null }))}</>)
    expect(screen.getByText("No retirement details were returned.")).toBeInTheDocument()
    expect(screen.getByText("No retirement reason was provided.")).toBeInTheDocument()
  })

  it("renders submit_insight from its input and plain-text result with linked markdown and evidence", () => {
    const input = {
      title: "Repeated grader timeout",
      category: "repeated_failure",
      severity: "high",
      confidence: 0.91,
      proposal_type: "create_job",
      evidence: [{ job_id: 200, workflow_id: 12, run_id: 99, kind: "run_transcript" }],
      suggested_prompt: "Fix **JOB-200** using https://example.test/evidence. ".repeat(20),
      memory_suggestion: "Remember to inspect `command_spans` before changing timeouts.",
      target_memory_id: 162
    }
    const cardContext = context({ toolName: "submit_insight", input, resultBody: "Suggestion #51 saved.", parsedResult: null })

    expect(submitInsightToolCard.collapsedSummary?.(cardContext)).toBe("Saved insight #51")
    render(<>{submitInsightToolCard.renderExpanded(cardContext)}</>)

    expect(screen.getByText("Suggestion #51 saved.")).toBeInTheDocument()
    expect(screen.getByText("Repeated grader timeout")).toBeInTheDocument()
    expect(screen.getByText("High")).toBeInTheDocument()
    expect(screen.getByText("repeated failure")).toBeInTheDocument()
    expect(screen.getByText("91% confidence")).toBeInTheDocument()
    expect(screen.getByText("Job")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "INSIGHT-51" })).toHaveAttribute("href", "/s/INSIGHT-51")
    expect(screen.getAllByRole("link", { name: "JOB-200" })[0]).toHaveAttribute("href", "/jobs/200")
    expect(screen.getByRole("link", { name: "WF-12" })).toHaveAttribute("href", "/jobs/200?tab=workflows#workflow-12")
    expect(screen.getByRole("link", { name: "RUN-99" })).toHaveAttribute("href", "/admin/runs/99/transcript")
    expect(screen.getAllByRole("link", { name: "MEMORY-162" })[0]).toHaveAttribute("href", "/memories")
    expect(screen.getAllByRole("button", { name: "Copy MEMORY-162 to clipboard" })).toHaveLength(2)
    expect(screen.getAllByRole("link", { name: "https://example.test/evidence" })[0]).toHaveAttribute("href", "https://example.test/evidence")
    expect(screen.getByText("Show more")).toBeInTheDocument()
    expect(screen.getByText("command_spans")).toBeInTheDocument()
  })

  it("handles submit_insight provider envelopes, pending, empty, and error states", () => {
    const input = { title: "Provider-shaped insight", category: "configuration", severity: "medium", confidence: 0.7 }
    const wrapped = context({
      toolName: "submit_insight",
      input,
      resultBody: "",
      parsedResult: { content: [{ type: "text", text: "Suggestion #53 saved." }] }
    })

    expect(submitInsightToolCard.collapsedSummary?.(wrapped)).toBe("Saved insight #53")
    render(<>{submitInsightToolCard.renderExpanded(wrapped)}</>)
    expect(screen.getByText("Suggestion #53 saved.")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "INSIGHT-53" })).toHaveAttribute("href", "/s/INSIGHT-53")

    const pending = context({ toolName: "submit_insight", input, resultBody: "", parsedResult: null })
    expect(submitInsightToolCard.collapsedSummary?.(pending)).toBe("Saving insight")
    render(<>{submitInsightToolCard.renderExpanded(pending)}</>)
    expect(screen.getByText("Saving insight")).toBeInTheDocument()
    expect(screen.getAllByText("Provider-shaped insight")).toHaveLength(2)
    expect(screen.queryByText("INSIGHT-pending")).not.toBeInTheDocument()

    const empty = context({ toolName: "submit_insight", resultBody: "", parsedResult: null })
    expect(submitInsightToolCard.collapsedSummary?.(empty)).toBeNull()
    expect(submitInsightToolCard.renderExpanded(context({ toolName: "submit_insight", resultBody: "", parsedResult: null }))).toBeNull()
  })

  it("renders submit_insight errors and structured provider results", () => {
    const failed = context({ toolName: "submit_insight", resultBody: "Database unavailable.", resultError: true, parsedResult: null })
    expect(submitInsightToolCard.collapsedSummary?.(failed)).toBe("Insight submission failed")
    render(<>{submitInsightToolCard.renderExpanded(failed)}</>)
    expect(screen.getByText("Database unavailable.")).toBeInTheDocument()

    const structured = context({
      toolName: "submit_insight",
      input: { title: "Structured insight" },
      resultBody: "",
      parsedResult: { structured_content: { data: { message: "Saved by provider.", insight_ids: [54] } } }
    })
    expect(submitInsightToolCard.collapsedSummary?.(structured)).toBe("Saved insight #54")
  })

  it("renders every update_insight input field, markdown, links, and the text result", () => {
    const longReason = `Changed after **RUN-99** and https://example.test/evidence. ${"More evidence. ".repeat(50)}`
    const cardContext = context({
      toolName: "update_insight",
      resultBody: "Suggestion #41 updated.",
      parsedResult: null,
      input: {
        target_insight_id: 41,
        reason: longReason,
        title: "Prepare failures share one cause",
        summary: "Now connected to **JOB-200**.",
        category: "repeated_failure",
        severity: "high",
        confidence: 0.94,
        proposal_type: "create_job",
        evidence: [{ job_id: 200, run_id: 99, kind: "run_transcript" }],
        suggested_prompt: "Fix **JOB-200**.",
        memory_suggestion: "Remember the shared setup.",
        target_memory_id: 12,
        stale_memory_text: "The old setup always succeeds.",
        stale_memory_evidence: "Contradicted by **RUN-99**."
      }
    })

    expect(updateInsightToolCard.collapsedSummary?.(cardContext)).toBe("Updated insight #41")
    render(<>{updateInsightToolCard.renderExpanded(cardContext)}</>)

    expect(screen.getByText("Suggestion #41 updated.")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "INSIGHT-41" })).toHaveAttribute("href", "/s/INSIGHT-41")
    expect(screen.getByText("Prepare failures share one cause")).toBeInTheDocument()
    expect(screen.getByText("94%")).toBeInTheDocument()
    expect(screen.getAllByRole("link", { name: "JOB-200" }).length).toBeGreaterThan(0)
    expect(screen.getAllByRole("link", { name: "RUN-99" }).length).toBeGreaterThan(0)
    expect(screen.getAllByRole("link", { name: "RUN-99" }).every((link) => link.getAttribute("href") === "/admin/runs/99/transcript")).toBe(true)
    expect(screen.getByText("MEMORY-12")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "https://example.test/evidence" })).toHaveAttribute("href", "https://example.test/evidence")
    expect(screen.getByRole("button", { name: "Show more" })).toBeInTheDocument()
  })

  it("renders partial, pending, cleared, empty, and provider-wrapped updates", () => {
    const wrappedContext = context({
      toolName: "update_insight",
      resultBody: JSON.stringify({ content: [{ type: "text", text: "Suggestion #42 updated." }] }),
      parsedResult: { content: [{ type: "text", text: "Suggestion #42 updated." }] },
      input: { target_insight_id: 42, reason: "Confidence increased.", confidence: 0.81, evidence: [], memory_suggestion: null }
    })

    expect(updateInsightToolCard.collapsedSummary?.(wrappedContext)).toBe("Updated insight #42")
    render(<>{updateInsightToolCard.renderExpanded(wrappedContext)}</>)
    expect(screen.getByText("81%")).toBeInTheDocument()
    expect(screen.getByText("Evidence will be cleared.")).toBeInTheDocument()
    expect(screen.getByText("This field will be cleared.")).toBeInTheDocument()

    const pendingContext = context({
      toolName: "update_insight",
      resultBody: "",
      parsedResult: null,
      input: { target_insight_id: 43, reason: "" }
    })
    expect(updateInsightToolCard.collapsedSummary?.(pendingContext)).toBe("Updating insight #43")
    render(<>{updateInsightToolCard.renderExpanded(pendingContext)}</>)
    expect(screen.getByText("Waiting for the update result.")).toBeInTheDocument()
    expect(screen.getByText("No changed fields were supplied.")).toBeInTheDocument()
    expect(screen.getByText("No reason supplied.")).toBeInTheDocument()
  })

  it("renders update_insight errors without exposing an incomplete success card", () => {
    const cardContext = context({
      toolName: "update_insight",
      resultBody: "Suggestion #44 is accepted and cannot be updated.",
      resultError: true,
      parsedResult: null,
      input: { target_insight_id: 44, reason: "Refresh it.", title: "New title" }
    })

    expect(updateInsightToolCard.collapsedSummary?.(cardContext)).toBe("Insight update failed")
    render(<>{updateInsightToolCard.renderExpanded(cardContext)}</>)
    expect(screen.getByText("Suggestion #44 is accepted and cannot be updated.")).toBeInTheDocument()
    expect(screen.queryByText("Changed fields")).not.toBeInTheDocument()
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

  it("renders isolated memory and supersession references without related prose", () => {
    render(
      <>
        {readInsightToolCard.renderExpanded(
          context({
            toolName: "read_insight",
            parsedResult: {
              insight: {
                ...baseInsight,
                target_memory_id: 18,
                superseded_by_insight_id: 44,
                superseded_by_job_id: 82
              }
            }
          })
        )}
      </>
    )

    expect(screen.getAllByRole("button", { name: "Copy MEMORY-18 to clipboard" })).toHaveLength(2)
    expect(screen.getByRole("link", { name: "INSIGHT-44" })).toHaveAttribute("href", "/s/INSIGHT-44")
    expect(screen.getByRole("link", { name: "JOB-82" })).toHaveAttribute("href", "/jobs/82")
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
