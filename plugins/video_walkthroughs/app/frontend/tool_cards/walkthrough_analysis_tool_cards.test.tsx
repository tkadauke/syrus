import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import { pluginToolCardRendererFor, type ToolCardContext } from "@app/pluginToolCards"
import { normalizedToolCardParsedResult } from "@app/routes/chat/toolRendering"
import analyzeWalkthroughSegmentToolCard, { examples as segmentExamples } from "./analyze_walkthrough_segment"
import getWalkthroughAnalysisToolCard, { examples as fullAnalysisExamples } from "./get_walkthrough_analysis"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "get_walkthrough_analysis",
    input: { walkthrough_id: 42 },
    resultBody: "{}",
    resultError: false,
    parsedResult: {},
    ...overrides
  }
}

const analysisReport = [
  "## Session summary",
  "Checkout works until Save silently fails.",
  "",
  "## Sections",
  "- **Checkout path** (00:00–00:40) — The user completes payment.",
  "- **Settings save** (01:05–01:30) — The save button appears inert.",
  "",
  "## Issues found (2)",
  "- **Save button does nothing** (high, settings, at 01:12, needs a closer look)",
  "  No confirmation or validation appears after Save.",
  "  On screen: A red toast appears but the code is too small.",
  "- **Low contrast helper text** (low, settings, at 00:20)",
  "  Gray helper text blends into the panel.",
  "",
  "## Narration transcript",
  "[01:12] I click save and nothing happens.",
  "",
  "## Open questions from the analysis",
  "The analysis flagged these ambiguities:",
  "- Should drafts autosave?"
].join("\n")

describe("video walkthrough analysis tool cards", () => {
  it("registers plugin-owned cards for the analysis tools", () => {
    expect(pluginToolCardRendererFor("get_walkthrough_analysis")).not.toBeNull()
    expect(pluginToolCardRendererFor("analyze_walkthrough_segment")).not.toBeNull()
  })

  it("summarizes and renders full walkthrough analysis with segments, issue severity, findings, transcript, and frames", () => {
    const parsedResult = {
      content: [
        { type: "text", text: analysisReport },
        { type: "text", text: "Screenshot — Save button does nothing (at 1:12):" },
        { type: "image", data: "jpeg", mimeType: "image/jpeg" }
      ]
    }

    expect(getWalkthroughAnalysisToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("Walkthrough analysis: 2 issues across 2 segments, 1 frame")

    render(<>{getWalkthroughAnalysisToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("Walkthrough analysis")).toBeInTheDocument()
    expect(screen.getByText("issues found")).toBeInTheDocument()
    expect(screen.getByText("Checkout works until Save silently fails.")).toBeInTheDocument()
    expect(screen.getByText("Checkout path")).toBeInTheDocument()
    expect(screen.getByText("00:00–00:40")).toBeInTheDocument()
    expect(screen.getAllByText("Save button does nothing").length).toBeGreaterThan(0)
    expect(screen.getByText("high")).toBeInTheDocument()
    expect(screen.getByText("needs a closer look")).toBeInTheDocument()
    expect(document.body).toHaveTextContent("No confirmation or validation appears after Save.")
    expect(screen.getByText("Low contrast helper text")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Open Save button does nothing" })).toBeInTheDocument()
    expect(screen.getByRole("img", { name: "Save button does nothing at 1:12" })).toHaveAttribute("src", "data:image/jpeg;base64,jpeg")
    expect(screen.getByText("WALKTHROUGH-42")).toBeInTheDocument()
    expect(screen.queryByRole("link", { name: "WALKTHROUGH-42" })).not.toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Copy WALKTHROUGH-42 to clipboard" })).toBeInTheDocument()
    expect(screen.getByText("[01:12] I click save and nothing happens.")).toBeInTheDocument()
    expect(screen.getByText("Should drafts autosave?")).toBeInTheDocument()
  })

  it("renders an empty/no-issues analysis as a successful empty state", () => {
    const parsedResult = {
      content: [
        {
          type: "text",
          text: [
            "## Session summary",
            "The walkthrough completed without visible errors.",
            "",
            "## Sections",
            "- **Happy path** (00:00–00:55) — The task completes.",
            "",
            "## Issues found",
            "(none — the walkthrough surfaced no problems)"
          ].join("\n")
        }
      ]
    }

    expect(getWalkthroughAnalysisToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("Walkthrough analysis: no issues across 1 segment")

    render(<>{getWalkthroughAnalysisToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("no issues")).toBeInTheDocument()
    expect(screen.getByText("No issues were detected in this walkthrough.")).toBeInTheDocument()
    expect(screen.getByText("Happy path")).toBeInTheDocument()
  })

  it("summarizes and renders segment analysis with observations, issues, timestamps, and note", () => {
    const parsedResult = {
      walkthrough_id: 42,
      range: "1:10–1:30",
      focus: "the exact error text",
      note: "The requested range was truncated.",
      analysis: {
        observations: ["The toast reads Save failed (E_TIMEOUT).", "The spinner remains active."],
        relevant_timestamps: ["1:12", "1:18"],
        issues: [
          {
            title: "Save timeout is visible",
            severity: "high",
            timestamp: "1:12",
            description: "The exact toast text is visible in the zoomed segment.",
            evidence: "Save failed (E_TIMEOUT)"
          }
        ]
      }
    }

    const cardContext = context({ toolName: "analyze_walkthrough_segment", input: { walkthrough_id: 42 }, parsedResult })
    expect(analyzeWalkthroughSegmentToolCard.collapsedSummary?.(cardContext)).toBe("Segment 1:10–1:30: 1 issue")

    render(<>{analyzeWalkthroughSegmentToolCard.renderExpanded(cardContext)}</>)

    expect(screen.getByText("Walkthrough segment")).toBeInTheDocument()
    expect(screen.getByText("analyzed")).toBeInTheDocument()
    expect(screen.getByText("1:10–1:30")).toBeInTheDocument()
    expect(screen.getByText("the exact error text")).toBeInTheDocument()
    expect(screen.getByText("The requested range was truncated.")).toBeInTheDocument()
    expect(screen.getByText("Save timeout is visible")).toBeInTheDocument()
    expect(screen.getByText("The toast reads Save failed (E_TIMEOUT).")).toBeInTheDocument()
    expect(screen.getByText("1:18")).toBeInTheDocument()
  })

  it("renders segment failures as recovery-oriented cards rather than raw JSON", () => {
    const parsedResult = {
      content: [{ type: "text", text: "Gemini's quota is busy right now (free-tier per-minute limits). Try the segment again in a minute." }],
      isError: true
    }
    const cardContext = context({
      toolName: "analyze_walkthrough_segment",
      input: { walkthrough_id: 42, start: "01:10", end: "08:30", focus: "everything" },
      parsedResult,
      resultError: true
    })

    expect(analyzeWalkthroughSegmentToolCard.collapsedSummary?.(cardContext)).toBe("Segment analysis failed")

    render(<>{analyzeWalkthroughSegmentToolCard.renderExpanded(cardContext)}</>)

    expect(screen.getByText("failed")).toBeInTheDocument()
    expect(screen.getByText(/Gemini's quota is busy/)).toBeInTheDocument()
    expect(screen.getByText("Gemini quota is temporarily unavailable. Wait briefly, then retry the analysis.")).toBeInTheDocument()
    expect(screen.queryByText(/"isError"/)).not.toBeInTheDocument()
  })

  it.each([
    ["Claude", { content: [{ type: "text", text: analysisReport }] }],
    ["Codex", { content: [{ type: "text", text: JSON.stringify({ content: [{ type: "text", text: analysisReport }] }) }] }],
    ["Muse", { result: { content: [{ type: "text", text: analysisReport }] } }]
  ])("renders the %s provider envelope", (_provider, envelope) => {
    const parsedResult = normalizedToolCardParsedResult(envelope)
    render(<>{getWalkthroughAnalysisToolCard.renderExpanded(context({ parsedResult }))}</>)
    expect(screen.getByText("Checkout works until Save silently fails.")).toBeInTheDocument()
    expect(screen.getByText("Checkout path")).toBeInTheDocument()
  })

  it("falls back to the complete markdown report when headings change", () => {
    const report = "# Review report\n\n**Save failed** after visiting https://example.test/settings."
    render(<>{getWalkthroughAnalysisToolCard.renderExpanded(context({ parsedResult: { content: [{ type: "text", text: report }] } }))}</>)

    expect(screen.getByText("Save failed", { selector: "strong" })).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "https://example.test/settings" })).toHaveAttribute("href", "https://example.test/settings")
  })

  it("renders the complete report when recognized and shifted headings are mixed", () => {
    const report = [
      "## Session overview",
      "**The renamed summary remains visible.**",
      "",
      "## Issues found (1)",
      "- **Save button does nothing** (high, settings, at 01:12)",
      "  The parsed issue remains available too."
    ].join("\n")
    render(<>{getWalkthroughAnalysisToolCard.renderExpanded(context({ parsedResult: { content: [{ type: "text", text: report }] } }))}</>)

    expect(screen.getByText("The renamed summary remains visible.", { selector: "strong" })).toBeInTheDocument()
    expect(screen.getAllByText("Save button does nothing").length).toBeGreaterThan(0)
  })

  it("renders pending and provider-specific error guidance", () => {
    const { rerender } = render(<>{getWalkthroughAnalysisToolCard.renderExpanded(context())}</>)
    expect(screen.getByText("pending")).toBeInTheDocument()
    expect(screen.getByText(/still pending/)).toBeInTheDocument()

    rerender(
      <>
        {getWalkthroughAnalysisToolCard.renderExpanded(
          context({ resultError: true, parsedResult: { content: [{ type: "text", text: "Gemini API key rejected" }] } })
        )}
      </>
    )
    expect(screen.getByText(/plugin credentials/)).toBeInTheDocument()

    rerender(
      <>
        {getWalkthroughAnalysisToolCard.renderExpanded(
          context({ resultError: true, parsedResult: { content: [{ type: "text", text: "Stored video was pruned" }] } })
        )}
      </>
    )
    expect(screen.getByText(/fresh walkthrough/)).toBeInTheDocument()
  })

  it("exports catalog examples for full, empty, segment, and failure states", () => {
    expect(fullAnalysisExamples.map((example) => example.id)).toEqual(["full_analysis", "empty_analysis", "pending_analysis", "failed_analysis"])
    expect(segmentExamples.map((example) => example.id)).toEqual(["segment_analysis", "segment_failure"])
  })
})
