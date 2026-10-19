import { fireEvent, render, screen } from "@testing-library/react"
import { beforeEach, describe, expect, it, vi } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import { normalizedToolCardParsedResult, normalizedToolName } from "../toolRendering"
import readWorkflowToolCard from "./read_workflow"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "read_workflow",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

describe("read_workflow tool card", () => {
  beforeEach(() => {
    Object.assign(navigator, {
      clipboard: { writeText: vi.fn().mockResolvedValue(undefined) }
    })
  })

  it("registers under the exact MCP tool name", () => {
    expect(readWorkflowToolCard.toolName).toBe("read_workflow")
    expect(normalizedToolName("mcp__syrus-chat-sidecar__read_workflow")).toBe(readWorkflowToolCard.toolName)
  })

  it("summarizes the collapsed row with the canonical WF id and state", () => {
    const parsedResult = { workflow: { id: 25606, state: "running" } }
    expect(readWorkflowToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("WF-25606 (running)")
  })

  it("renders the header, job link value, trigger kind, agent provider, cost, summary, and step/run timeline", () => {
    const parsedResult = {
      workflow: {
        id: 25606,
        job_id: 4221,
        trigger_kind: "initial",
        state: "running",
        agent_provider: "claude",
        summary: `## Implementation\n\n${"Explaining the workflow changes in detail. ".repeat(30)}`,
        step_count: 2,
        run_count: 3,
        total_cost_usd: "1.75",
        created_at: "2025-12-31T23:59:00Z",
        started_at: "2026-01-01T00:00:00Z",
        finished_at: "2026-01-01T00:05:00Z",
        steps: [
          {
            id: 1,
            kind: "implement",
            state: "succeeded",
            position: 0,
            details: "Run the focused frontend checks.",
            run_count: 2,
            started_at: "2026-01-01T00:00:00Z",
            finished_at: "2026-01-01T00:02:00Z",
            runs: [
              {
                id: 9,
                state: "succeeded",
                agent_outcome: "success",
                agent_summary: `**Changed** the code. ${"More context. ".repeat(50)}`,
                started_at: "2026-01-01T00:00:00Z",
                finished_at: "2026-01-01T00:02:00Z",
                cost_usd: "0.42"
              }
            ]
          }
        ]
      }
    }

    render(<>{readWorkflowToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("WF-25606")).toBeInTheDocument()
    expect(screen.getByText("running")).toBeInTheDocument()
    expect(screen.getByText("initial")).toBeInTheDocument()
    expect(screen.getByText("claude")).toBeInTheDocument()
    expect(screen.getByText("$1.7500")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "WF-25606" })).toHaveAttribute("href", "/jobs/4221?tab=workflows#workflow-25606")
    expect(screen.getByRole("link", { name: "JOB-4221" })).toHaveAttribute("href", "/jobs/4221")
    expect(screen.getByText("Implementation")).toBeInTheDocument()
    expect(screen.getAllByText("Steps")).toHaveLength(2)
    expect(screen.getByText("2", { selector: "div.font-mono" })).toBeInTheDocument()
    expect(screen.getByText("Runs")).toBeInTheDocument()
    expect(screen.getByText("3", { selector: "div.font-mono" })).toBeInTheDocument()
    expect(screen.getByText("implement")).toBeInTheDocument()
    expect(screen.getByText("#0")).toBeInTheDocument()
    expect(screen.getByText("2 runs")).toBeInTheDocument()
    expect(screen.getByText("Run the focused frontend checks.")).toBeInTheDocument()
    expect(screen.getByText("2025-12-31T23:59:00Z")).toBeInTheDocument()
    expect(screen.getAllByText("succeeded")).toHaveLength(2)
    expect(screen.getByRole("link", { name: "RUN-9" })).toHaveAttribute("href", "/jobs/4221?tab=workflows#workflow-25606")
    expect(screen.getByText("success")).toBeInTheDocument()
    expect(screen.getByText("$0.4200")).toBeInTheDocument()
    expect(screen.getByText("Changed")).toBeInTheDocument()
    expect(screen.getAllByRole("button", { name: "Show more" })).toHaveLength(2)
    fireEvent.click(screen.getAllByRole("button", { name: "Show more" })[1])
    expect(screen.getByRole("dialog", { name: "Full summary for RUN-9" })).toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: "Copy WF-25606 to clipboard" }))
    fireEvent.click(screen.getByRole("button", { name: "Copy RUN-9 to clipboard" }))
    expect(navigator.clipboard.writeText).toHaveBeenCalledWith("WF-25606")
    expect(navigator.clipboard.writeText).toHaveBeenCalledWith("RUN-9")
  })

  it("renders an explicit empty state when the workflow has no steps", () => {
    const parsedResult = { workflow: { id: 1, state: "queued" } }
    render(<>{readWorkflowToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("WF-1")).toBeInTheDocument()
    expect(screen.getByText("Steps")).toBeInTheDocument()
    expect(screen.getAllByText("0", { selector: "div.font-mono" })).toHaveLength(2)
    expect(screen.getByText("This workflow has no steps.")).toBeInTheDocument()
  })

  it.each([
    [
      "content text",
      { content: [{ type: "text", text: JSON.stringify({ workflow: { id: 81, state: "running" } }) }], structured_content: null },
      "WF-81 (running)"
    ],
    [
      "structured content",
      {
        content: [{ type: "text", text: JSON.stringify({ workflow: { id: 1, state: "stale" } }) }],
        structured_content: { workflow: { id: 82, state: "succeeded" } }
      },
      "WF-82 (succeeded)"
    ]
  ])("renders the shared %s MCP envelope normalization", (_label, envelope, expected) => {
    const parsedResult = normalizedToolCardParsedResult(envelope)
    expect(readWorkflowToolCard.collapsedSummary?.(context({ parsedResult }))).toBe(expected)
    render(<>{readWorkflowToolCard.renderExpanded(context({ parsedResult }))}</>)
    expect(screen.getByText(expected.split(" ")[0])).toBeInTheDocument()
  })

  it("renders inaccessible and not-found results as an error card", () => {
    const errorContext = context({
      input: { workflow_id: 404 },
      resultError: true,
      resultBody: "Workflow is inaccessible or was not found.",
      parsedResult: { error: "Workflow is inaccessible or was not found." }
    })

    expect(readWorkflowToolCard.collapsedSummary?.(errorContext)).toBe("WF-404 could not be read")
    render(<>{readWorkflowToolCard.renderExpanded(errorContext)}</>)
    expect(screen.getByText("WF-404")).toBeInTheDocument()
    expect(screen.getByText("failed")).toBeInTheDocument()
    expect(screen.getByText("Workflow is inaccessible or was not found.")).toBeInTheDocument()
  })

  it("falls back to null for a malformed payload (missing workflow object)", () => {
    expect(readWorkflowToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(readWorkflowToolCard.renderExpanded(context({ parsedResult: { oops: true } }))).toBeNull()
  })

  it("falls back to null for a non-object payload", () => {
    expect(readWorkflowToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
