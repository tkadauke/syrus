import { fireEvent, render, screen, within } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import { normalizedToolCardParsedResult, normalizedToolName } from "../toolRendering"
import listJobWorkflowsToolCard from "./list_job_workflows"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "list_job_workflows",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

const workflow = {
  id: 42,
  trigger_kind: "pr_comment",
  state: "succeeded",
  planned_execution: {
    project_label: "repo",
    target_label: "//:test",
    capabilities: { os: ["linux"], arch: ["arm64"] },
    source: "explicit"
  },
  summary: "Addressed **review feedback**",
  step_count: 5,
  run_count: 6,
  created_at: "2026-01-01T00:00:00Z",
  started_at: "2026-01-01T00:01:00Z",
  finished_at: "2026-01-01T00:02:14Z"
}

describe("list_job_workflows tool card", () => {
  afterEach(() => vi.restoreAllMocks())

  it("registers under the normalized MCP tool name", () => {
    expect(normalizedToolName("mcp__syrus-chat-sidecar__list_job_workflows")).toBe(listJobWorkflowsToolCard.toolName)
  })

  it("summarizes the Job and workflow count", () => {
    const parsedResult = { job_id: 9, workflows: [workflow, { id: 2, state: "failed" }] }
    expect(listJobWorkflowsToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("JOB-9 · 2 Workflows")
  })

  it("renders linked Job and workflow references plus all workflow metadata", () => {
    render(<>{listJobWorkflowsToolCard.renderExpanded(context({ parsedResult: { job_id: 9, workflows: [workflow] } }))}</>)

    expect(screen.getByRole("link", { name: "JOB-9" })).toHaveAttribute("href", "/jobs/9")
    expect(screen.getByRole("link", { name: "WF-42" })).toHaveAttribute("href", "/jobs/9?tab=workflows#workflow-42")
    expect(screen.getByText("pr_comment")).toBeInTheDocument()
    expect(screen.getByText("succeeded")).toBeInTheDocument()
    expect(screen.getByText("review feedback")).toBeInTheDocument()
    expect(screen.getByText("5 / 6")).toBeInTheDocument()
    expect(screen.getByText("os: linux")).toBeInTheDocument()
    expect(screen.getByText("arch: arm64")).toBeInTheDocument()
    expect(screen.getByText("repo")).toBeInTheDocument()
    expect(screen.getByText("//:test")).toBeInTheDocument()
    expect(screen.getByText("explicit")).toBeInTheDocument()
    expect(document.querySelector('time[datetime="2026-01-01T00:00:00Z"]')).toBeInTheDocument()
    expect(document.querySelector('time[datetime="2026-01-01T00:01:00Z"]')).toBeInTheDocument()
    expect(document.querySelector('time[datetime="2026-01-01T00:02:14Z"]')).toBeInTheDocument()
    expect(screen.getByText("1m 14s")).toBeInTheDocument()
  })

  it("uses the responsive shared table labels on mobile", () => {
    render(<>{listJobWorkflowsToolCard.renderExpanded(context({ parsedResult: { job_id: 9, workflows: [workflow] } }))}</>)

    expect(screen.getByRole("table")).toHaveClass("block", "sm:table")
    expect(screen.getByText("WF-42").closest("td")).toHaveAttribute("data-label", "Workflow")
    expect(screen.getByText("review feedback").closest("td")).toHaveAttribute("data-label", "Summary")
  })

  it("shows the complete markdown summary on request", () => {
    vi.spyOn(HTMLElement.prototype, "clientHeight", "get").mockReturnValue(48)
    vi.spyOn(HTMLElement.prototype, "scrollHeight", "get").mockReturnValue(96)
    const payloadSizedSummary = `**Result:** ${"responsive workflow details ".repeat(8)}`
    expect(payloadSizedSummary.length).toBeLessThanOrEqual(300)
    render(<>{listJobWorkflowsToolCard.renderExpanded(context({ parsedResult: { job_id: 9, workflows: [{ ...workflow, summary: payloadSizedSummary }] } }))}</>)

    fireEvent.click(screen.getByRole("button", { name: "Show more" }))
    const dialog = screen.getByRole("dialog", { name: "Workflow 42 summary" })
    expect(within(dialog).getByText("Result:")).toBeInTheDocument()
    expect(dialog).toHaveTextContent("responsive workflow details")
  })

  it("keeps links working from the result when collapsed context has no input", () => {
    render(<>{listJobWorkflowsToolCard.renderExpanded(context({ parsedResult: { job_id: 9, workflows: [workflow] } }))}</>)
    expect(screen.getByRole("link", { name: "WF-42" })).toHaveAttribute("href", "/jobs/9?tab=workflows#workflow-42")
  })

  it("uses the input Job id for older recorded results", () => {
    render(<>{listJobWorkflowsToolCard.renderExpanded(context({ input: { job_id: 7 }, parsedResult: { workflows: [{ id: 8, state: "queued" }] } }))}</>)
    expect(screen.getByRole("link", { name: "JOB-7" })).toHaveAttribute("href", "/jobs/7")
    expect(screen.getByRole("link", { name: "WF-8" })).toHaveAttribute("href", "/jobs/7?tab=workflows#workflow-8")
  })

  it.each([
    ["content text", { content: [{ type: "text", text: JSON.stringify({ job_id: 9, workflows: [workflow] }) }] }],
    ["structured content", { structured_content: { job_id: 9, workflows: [workflow] } }]
  ])("renders the shared-normalized %s MCP envelope", (_label, envelope) => {
    const parsedResult = normalizedToolCardParsedResult(envelope)
    render(<>{listJobWorkflowsToolCard.renderExpanded(context({ parsedResult }))}</>)
    expect(screen.getByRole("link", { name: "WF-42" })).toHaveAttribute("href", "/jobs/9?tab=workflows#workflow-42")
  })

  it("renders errors as a dedicated card", () => {
    const cardContext = context({ input: { job_id: 9 }, resultBody: "Job not found", resultError: true })
    expect(listJobWorkflowsToolCard.collapsedSummary?.(cardContext)).toBe("JOB-9 workflows failed")
    render(<>{listJobWorkflowsToolCard.renderExpanded(cardContext)}</>)
    expect(screen.getByRole("link", { name: "JOB-9" })).toHaveAttribute("href", "/jobs/9")
    expect(screen.getByText("Job not found")).toBeInTheDocument()
  })

  it("renders explicit empty and optional-field states", () => {
    const { rerender } = render(<>{listJobWorkflowsToolCard.renderExpanded(context({ parsedResult: { job_id: 9, workflows: [] } }))}</>)
    expect(screen.getByText("No Workflows found.")).toBeInTheDocument()

    rerender(<>{listJobWorkflowsToolCard.renderExpanded(context({ parsedResult: { job_id: 9, workflows: [{ id: 7, state: "queued" }] } }))}</>)
    expect(screen.getByText("WF-7")).toBeInTheDocument()
    expect(screen.getAllByText("—").length).toBeGreaterThan(0)
  })

  it("falls back to the generic renderer for malformed payloads", () => {
    expect(listJobWorkflowsToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(listJobWorkflowsToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
