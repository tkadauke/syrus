import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import { normalizedToolCardParsedResult, normalizedToolName } from "@app/routes/chat/toolRendering"
import type { ToolCardContext } from "@app/pluginToolCards"
import resumeScheduledTaskToolCard, { examples } from "./resume_scheduled_task"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "resume_scheduled_task",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

const resumed = { scheduled_task_id: 12, label: "Nightly main-branch health check", enabled: true }
const detailed = {
  ...resumed,
  scheduled_task: {
    id: 12,
    label: "Nightly main-branch health check",
    state: "scheduled",
    repository_id: 8,
    repository_slug: "tkadauke/syrus",
    next_fire_at: "2026-10-24T03:00:00Z"
  }
}

describe("resume_scheduled_task tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(resumeScheduledTaskToolCard.toolName).toBe("resume_scheduled_task")
  })

  it("summarizes the collapsed row with the resumed label and id", () => {
    expect(resumeScheduledTaskToolCard.collapsedSummary?.(context({ parsedResult: resumed }))).toBe("Resumed 'Nightly main-branch health check' (#12)")
  })

  it("renders the resumed outcome", () => {
    render(<>{resumeScheduledTaskToolCard.renderExpanded(context({ parsedResult: resumed }))}</>)

    expect(screen.getByText("resumed")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "TASK-12" })).toHaveAttribute("href", "/scheduled_tasks/12")
    expect(screen.getByText("Nightly main-branch health check")).toBeInTheDocument()
    expect(screen.getByText("Enabled")).toBeInTheDocument()
    expect(screen.getByText("Yes")).toBeInTheDocument()
    expect(screen.getByText("This task is scheduled again and will fire on its next due tick.")).toBeInTheDocument()
  })

  it("renders state, repository, and relative, local, and UTC next-fire times", () => {
    render(<>{resumeScheduledTaskToolCard.renderExpanded(context({ parsedResult: detailed }))}</>)

    expect(screen.getByText("scheduled")).toBeInTheDocument()
    expect(screen.getByText("Enabled")).toBeInTheDocument()
    expect(screen.getByText("Yes")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "tkadauke/syrus" })).toHaveAttribute("href", "/repositories/8")
    expect(screen.getByText("Next fire (relative)")).toBeInTheDocument()
    expect(screen.getByText("Next fire (local)")).toBeInTheDocument()
    expect(screen.getByText("Next fire (UTC)")).toBeInTheDocument()
    expect(screen.getByText(/AM UTC|PM UTC/)).toBeInTheDocument()
    expect(document.querySelector("time")).toHaveTextContent(/ago|today|tomorrow|in /)
  })

  it.each(["scheduled task is already enabled", "scheduled task not found: 404"])("renders a styled error and preserves the input task link: %s", (message) => {
    render(<>{resumeScheduledTaskToolCard.renderExpanded(context({ input: { scheduled_task_id: 404 }, resultError: true, resultBody: message }))}</>)

    expect(screen.getByText("failed")).toBeInTheDocument()
    expect(screen.getByText(message)).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "TASK-404" })).toHaveAttribute("href", "/scheduled_tasks/404")
  })

  it.each([
    ["Codex structured content", { structured_content: detailed }],
    ["Claude text content", { content: [{ type: "text", text: JSON.stringify(detailed) }] }]
  ])("renders normalized %s envelopes", (_label, envelope) => {
    const parsedResult = normalizedToolCardParsedResult(envelope)
    const toolContext = context({ toolName: normalizedToolName("mcp__syrus-chat-sidecar__resume_scheduled_task"), parsedResult })

    render(<>{resumeScheduledTaskToolCard.renderExpanded(toolContext)}</>)
    expect(screen.getByRole("link", { name: "TASK-12" })).toBeInTheDocument()
    expect(screen.getByText("scheduled")).toBeInTheDocument()
  })

  it("renders a styled malformed state with the requested task link", () => {
    const parsedResult = { oops: true }
    const toolContext = context({ input: { scheduled_task_id: 12 }, parsedResult, resultSettled: true })

    expect(resumeScheduledTaskToolCard.collapsedSummary?.(toolContext)).toBe("Scheduled task resume returned no details")
    render(<>{resumeScheduledTaskToolCard.renderExpanded(toolContext)}</>)
    expect(screen.getByText("unknown")).toBeInTheDocument()
    expect(screen.getByText("No usable resume result was returned.")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "TASK-12" })).toHaveAttribute("href", "/scheduled_tasks/12")
  })

  it.each([null, "not json"])("renders a styled empty or non-object result: %p", (parsedResult) => {
    const toolContext = context({ input: { scheduled_task_id: 12 }, parsedResult, resultSettled: true })

    render(<>{resumeScheduledTaskToolCard.renderExpanded(toolContext)}</>)
    expect(screen.getByText("No usable resume result was returned.")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "TASK-12" })).toBeInTheDocument()
  })

  it("publishes success, error, and empty catalog examples", () => {
    expect(examples.map((example) => example.id)).toEqual(["resumed_with_next_fire", "already_enabled_error", "empty_response"])
  })
})
