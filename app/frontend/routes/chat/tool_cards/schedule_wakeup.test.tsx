import { fireEvent, render, screen, within } from "@testing-library/react"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import { setSlugReferenceRegistryForTests } from "../../../lib/slugReferenceRegistry"
import { normalizedToolCardParsedResult, normalizedToolName } from "../toolRendering"
import scheduleWakeupToolCard, { examples } from "./schedule_wakeup"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return { toolName: "schedule_wakeup", resultBody: "", resultError: false, parsedResult: null, input: {}, ...overrides }
}

describe("schedule_wakeup tool card", () => {
  beforeEach(() => {
    vi.setSystemTime(new Date("2026-10-19T12:00:00Z"))
    setSlugReferenceRegistryForTests([
      {
        prefix: "JOB",
        type: "job",
        displayLabel: "Job",
        copyable: true,
        linkable: true,
        previewAvailable: false,
        linkifiesGeneratedText: true,
        hrefTemplate: "/s/JOB-:id",
        mobileInteractionHints: {},
        pluginPreviewComponent: null
      }
    ])
  })
  afterEach(() => {
    vi.useRealTimers()
    setSlugReferenceRegistryForTests(null)
  })

  it("registers under the provider-normalized MCP tool name", () => {
    expect(scheduleWakeupToolCard.toolName).toBe("schedule_wakeup")
    expect(normalizedToolName("mcp__syrus-chat-sidecar__schedule_wakeup")).toBe(scheduleWakeupToolCard.toolName)
    expect(normalizedToolName("syrus-chat-sidecar.schedule_wakeup")).toBe(scheduleWakeupToolCard.toolName)
  })

  it("renders absolute fire time, relative time, UTC, result, linked wakeup, and markdown prompt", () => {
    const parsedResult = { wakeup_id: 7, fire_at: "2026-10-19T14:00:00Z", message: "Wakeup scheduled" }
    const input = { prompt: "Review **JOB-42** at https://example.test/status", fire_at: "2026-10-19T14:00:00Z" }

    render(<>{scheduleWakeupToolCard.renderExpanded(context({ input, parsedResult }))}</>)

    expect(screen.getByText("WAKEUP-7")).toBeInTheDocument()
    expect(screen.getByText(/in 2 hours/)).toBeInTheDocument()
    expect(screen.getByText("2026-10-19T14:00:00.000Z UTC")).toBeInTheDocument()
    expect(screen.getByText("Wakeup scheduled")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "JOB-42" })).toHaveAttribute("href", "/s/JOB-42")
    expect(screen.getByRole("link", { name: "https://example.test/status" })).toHaveAttribute("href", "https://example.test/status")
    expect(scheduleWakeupToolCard.collapsedSummary?.(context({ input, parsedResult }))).toBe("Wakeup scheduled in 2 hours")
  })

  it("renders a relative delay while the call is pending", () => {
    render(<>{scheduleWakeupToolCard.renderExpanded(context({ input: { prompt: "Check later", delay_minutes: 30 } }))}</>)

    expect(screen.getByText("pending")).toBeInTheDocument()
    expect(screen.getByText("30 minutes")).toBeInTheDocument()
    expect(screen.getByText("Check later")).toBeInTheDocument()
    expect(scheduleWakeupToolCard.collapsedSummary?.(context({ input: { prompt: "Check later", delay_minutes: 30 } }))).toBe("Scheduling wakeup...")
  })

  it("renders an empty prompt state and a styled plain-text error", () => {
    const errorContext = context({ resultError: true, resultBody: "delay_minutes must be between 1 and 1440" })
    const { container } = render(<>{scheduleWakeupToolCard.renderExpanded(errorContext)}</>)

    expect(screen.getByText("failed")).toBeInTheDocument()
    expect(screen.getByText("delay_minutes must be between 1 and 1440")).toHaveClass("text-danger-text")
    expect(screen.getByText("No prompt provided.")).toBeInTheDocument()
    expect(container.querySelector(".before\\:bg-danger-border")).toBeInTheDocument()
  })

  it("renders structured errors from differently shaped MCP envelopes", () => {
    const envelope = { content: [{ type: "text", text: JSON.stringify({ error: "fire_at must be in the future" }) }], isError: true }
    const parsedResult = normalizedToolCardParsedResult(envelope)

    render(<>{scheduleWakeupToolCard.renderExpanded(context({ resultError: true, parsedResult, resultBody: JSON.stringify(envelope) }))}</>)

    expect(screen.getByText("fire_at must be in the future")).toBeInTheDocument()
  })

  it("shows more for a long markdown prompt and provides catalog examples", () => {
    const prompt = `**Review plan** ${"with more context ".repeat(80)}`
    render(<>{scheduleWakeupToolCard.renderExpanded(context({ input: { prompt, delay_minutes: 5 } }))}</>)

    fireEvent.click(screen.getByRole("button", { name: "Show more" }))
    expect(within(screen.getByRole("dialog", { name: "Prompt" })).getByText("Review plan")).toBeInTheDocument()
    expect(examples.map((example) => example.id)).toEqual(["scheduled_absolute", "validation_error"])
  })
})
