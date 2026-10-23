import { fireEvent, render, screen, within } from "@testing-library/react"
import { beforeEach, describe, expect, it, vi } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import { normalizedToolCardParsedResult } from "@app/routes/chat/toolRendering"
import readScheduledTaskToolCard, { examples } from "./read_scheduled_task"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "read_scheduled_task",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

const task = {
  id: 12,
  repository_id: 7,
  repository_slug: "tkadauke/syrus",
  label: "Nightly main-branch health check",
  kind: "cron",
  state: "scheduled",
  cron_expression: "0 3 * * *",
  schedule_input: "Every day at 3am",
  schedule_explanation: "Runs daily at 3:00 AM UTC",
  schedule_timezone: "UTC",
  fire_at: null,
  pr_pileup_policy: "skip",
  enabled: true,
  last_fired_at: "2026-09-05T03:00:00Z",
  last_successful_fire_at: "2026-09-05T03:00:00Z",
  consecutive_failure_count: 0,
  next_fire_at: "2026-09-06T03:00:00Z",
  created_at: "2026-08-01T00:00:00Z",
  prompt: "Survey main for failing graders and open a repair Job if anything is red."
}

describe("read_scheduled_task tool card", () => {
  beforeEach(() => {
    Object.assign(navigator, {
      clipboard: { writeText: vi.fn().mockResolvedValue(undefined) }
    })
  })

  it("registers under the exact MCP tool name", () => {
    expect(readScheduledTaskToolCard.toolName).toBe("read_scheduled_task")
  })

  it("summarizes the collapsed row with the label, id, and state", () => {
    const parsedResult = { scheduled_task: task }

    expect(readScheduledTaskToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("Nightly main-branch health check (#12, scheduled)")
  })

  it("renders the schedule, repository, and firing history", () => {
    render(<>{readScheduledTaskToolCard.renderExpanded(context({ parsedResult: { scheduled_task: task } }))}</>)

    expect(screen.getByText("Nightly main-branch health check")).toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: "Copy TASK-12 to clipboard" }))
    expect(navigator.clipboard.writeText).toHaveBeenCalledWith("TASK-12")
    expect(screen.getByText("scheduled")).toBeInTheDocument()
    expect(screen.getByText("cron")).toBeInTheDocument()
    expect(screen.getByText("Runs daily at 3:00 AM UTC (UTC)")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "tkadauke/syrus" })).toHaveAttribute("href", "/repositories/7")
    expect(screen.getAllByText(/UTC:/)).toHaveLength(4)
    expect(screen.getByText("skip")).toBeInTheDocument()
    expect(screen.getByText("Every day at 3am")).toBeInTheDocument()
    expect(screen.getByText("0 3 * * *")).toBeInTheDocument()
    expect(screen.getByText("Created")).toBeInTheDocument()
  })

  it("renders linked markdown and exposes a Show more modal with copy", () => {
    const prompt = `Review **main**, visit https://example.test/status, and update JOB-42. ${"More context. ".repeat(80)}`
    const onLinkClick = vi.fn()
    render(<>{readScheduledTaskToolCard.renderExpanded(context({ onLinkClick, parsedResult: { scheduled_task: { ...task, prompt } } }))}</>)

    expect(screen.getByText("Prompt")).toBeInTheDocument()
    expect(screen.getByText("main")).toBeInTheDocument()
    const inlineLink = screen.getByRole("link", { name: "https://example.test/status" })
    expect(inlineLink).toHaveAttribute("href", "https://example.test/status")
    fireEvent.click(inlineLink)
    expect(onLinkClick).toHaveBeenCalledWith((inlineLink as HTMLAnchorElement).href, expect.anything())
    expect(screen.getByTestId("markdown-preview-content")).toHaveTextContent("JOB-42")

    fireEvent.click(screen.getByRole("button", { name: "Show more" }))
    const modalLink = within(screen.getByRole("dialog")).getByRole("link", { name: "https://example.test/status" })
    fireEvent.click(modalLink)
    expect(onLinkClick).toHaveBeenCalledWith((modalLink as HTMLAnchorElement).href, expect.anything())
    expect(onLinkClick).toHaveBeenCalledTimes(2)
    fireEvent.click(screen.getByRole("button", { name: "Copy Prompt to clipboard" }))
    expect(navigator.clipboard.writeText).toHaveBeenCalledWith(prompt)
  })

  it("renders a paused task and its failure count", () => {
    const parsedResult = { scheduled_task: { ...task, state: "paused", enabled: false, consecutive_failure_count: 2 } }

    render(<>{readScheduledTaskToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("paused")).toBeInTheDocument()
    expect(screen.getByText("disabled")).toBeInTheDocument()
    expect(screen.getByText("2 consecutive failures")).toBeInTheDocument()
  })

  it("renders without a prompt disclosure when the prompt is missing", () => {
    const { prompt: _prompt, ...taskWithoutPrompt } = task
    const parsedResult = { scheduled_task: taskWithoutPrompt }

    render(<>{readScheduledTaskToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.queryByText("Prompt")).not.toBeInTheDocument()
  })

  it("renders the prompt empty state when the result includes a blank prompt", () => {
    render(<>{readScheduledTaskToolCard.renderExpanded(context({ parsedResult: { scheduled_task: { ...task, prompt: "  " } } }))}</>)

    expect(screen.getByText("Prompt")).toBeInTheDocument()
    expect(screen.getByText("No prompt was provided.")).toBeInTheDocument()
  })

  it.each([
    ["structured content", { structured_content: { scheduled_task: task } }],
    ["text content", { content: [{ type: "text", text: JSON.stringify({ scheduled_task: task }) }] }]
  ])("renders the normalized %s provider envelope", (_label, envelope) => {
    const parsedResult = normalizedToolCardParsedResult(envelope)

    expect(readScheduledTaskToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("Nightly main-branch health check (#12, scheduled)")
  })

  it("publishes reviewable detail, empty, and error catalog examples", () => {
    expect(examples.map((example) => example.id)).toEqual(["recurring_task_details", "blank_prompt", "not_found"])
  })

  it("falls back to null for a malformed payload", () => {
    const parsedResult = { oops: true }

    expect(readScheduledTaskToolCard.collapsedSummary?.(context({ parsedResult }))).toBeNull()
    expect(readScheduledTaskToolCard.renderExpanded(context({ parsedResult }))).toBeNull()
  })

  it("renders structured tool errors with the shared scheduled-task error card", () => {
    const parsedResult = { error: { message: "scheduled task not found" } }
    render(<>{readScheduledTaskToolCard.renderExpanded(context({ resultError: true, parsedResult }))}</>)

    expect(screen.getByText("Scheduled task")).toBeInTheDocument()
    expect(screen.getByText("scheduled task not found")).toBeInTheDocument()
    expect(readScheduledTaskToolCard.collapsedSummary?.(context({ resultError: true, parsedResult }))).toBe("Scheduled task request failed")
  })

  it("falls back to null when the task payload is missing required fields", () => {
    const parsedResult = { scheduled_task: { id: 12 } }

    expect(readScheduledTaskToolCard.collapsedSummary?.(context({ parsedResult }))).toBeNull()
    expect(readScheduledTaskToolCard.renderExpanded(context({ parsedResult }))).toBeNull()
  })

  it("falls back to null for a non-object payload", () => {
    const parsedResult = "not json"

    expect(readScheduledTaskToolCard.collapsedSummary?.(context({ parsedResult }))).toBeNull()
    expect(readScheduledTaskToolCard.renderExpanded(context({ parsedResult }))).toBeNull()
  })
})
