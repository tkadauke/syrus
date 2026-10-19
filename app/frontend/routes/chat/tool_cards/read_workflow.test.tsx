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
        summary: "Implementing tool cards",
        total_cost_usd: "1.75",
        started_at: "2026-01-01T00:00:00Z",
        finished_at: "2026-01-01T00:05:00Z",
        steps: [
          {
            id: 1,
            kind: "implement",
            state: "succeeded",
            position: 0,
            started_at: "2026-01-01T00:00:00Z",
            finished_at: "2026-01-01T00:02:00Z",
            runs: [
              {
                id: 9,
                state: "succeeded",
                agent_outcome: "success",
                agent_summary: "changed the code",
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
    expect(screen.getByText("Implementing tool cards")).toBeInTheDocument()
    expect(screen.getByText("implement")).toBeInTheDocument()
    expect(screen.getAllByText("succeeded")).toHaveLength(2)
    expect(screen.getByRole("link", { name: "RUN-9" })).toHaveAttribute("href", "/jobs/4221?tab=workflows#workflow-25606")
    expect(screen.getByText("success")).toBeInTheDocument()
    expect(screen.getByText("$0.4200")).toBeInTheDocument()
    expect(screen.getByText("changed the code")).toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: "Copy WF-25606 to clipboard" }))
    fireEvent.click(screen.getByRole("button", { name: "Copy RUN-9 to clipboard" }))
    expect(navigator.clipboard.writeText).toHaveBeenCalledWith("WF-25606")
    expect(navigator.clipboard.writeText).toHaveBeenCalledWith("RUN-9")
  })

  it("renders step metadata, markdown, counts, and an explicit empty state", () => {
    const parsedResult = {
      workflow: {
        id: 12,
        state: "running",
        step_count: 1,
        run_count: 2,
        created_at: "2026-10-19T10:00:00Z",
        steps: [{ id: 3, kind: "implement", state: "running", position: 2, details: "Fixed **important** behavior.", run_count: 2, runs: [] }]
      }
    }
    render(<>{readWorkflowToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("1 steps")).toBeInTheDocument()
    expect(screen.getAllByText("2 runs")).toHaveLength(2)
    expect(screen.getByText("Position 2")).toBeInTheDocument()
    expect(screen.getByText("important")).toBeInTheDocument()
    expect(screen.getByText("2026-10-19T10:00:00Z")).toBeInTheDocument()

    const empty = { workflow: { id: 13, state: "queued", step_count: 0, run_count: 0, steps: [] } }
    render(<>{readWorkflowToolCard.renderExpanded(context({ parsedResult: empty }))}</>)
    expect(screen.getByText("No steps have been created for this Workflow.")).toBeInTheDocument()
  })

  it("offers Show more for summaries within the tool's real 300/500 character limits", () => {
    const workflowSummary = `**Workflow:** ${"w".repeat(280)}`
    const runSummary = `**Run:** ${"r".repeat(480)}`
    const parsedResult = {
      workflow: {
        id: 14,
        state: "succeeded",
        summary: workflowSummary,
        steps: [{ id: 4, kind: "implement", state: "succeeded", runs: [{ id: 5, state: "succeeded", agent_summary: runSummary }] }]
      }
    }
    render(<>{readWorkflowToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getAllByRole("button", { name: "Show more" })).toHaveLength(2)
    fireEvent.click(screen.getAllByRole("button", { name: "Show more" })[0])
    expect(screen.getByRole("dialog", { name: "Workflow summary" })).toHaveTextContent(`Workflow: ${"w".repeat(280)}`)
  })

  it("renders content text and structured content envelopes through the shared normalizer", () => {
    const payload = { workflow: { id: 15, state: "running", steps: [] } }
    const textEnvelope = { content: [{ type: "text", text: JSON.stringify(payload) }], structured_content: null }
    const structuredEnvelope = { content: [{ type: "text", text: "ignored" }], structured_content: payload }

    for (const envelope of [textEnvelope, structuredEnvelope]) {
      const parsedResult = normalizedToolCardParsedResult(envelope)
      expect(readWorkflowToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("WF-15 (running)")
    }
    expect(normalizedToolName("mcp__syrus-chat-sidecar__read_workflow")).toBe("read_workflow")
  })

  it("renders inaccessible and not-found errors as a dedicated card", () => {
    const errorContext = context({ input: { workflow_id: 999 }, resultError: true, resultBody: "Workflow not found or inaccessible" })
    expect(readWorkflowToolCard.collapsedSummary?.(errorContext)).toBe("Workflow lookup failed")
    render(<>{readWorkflowToolCard.renderExpanded(errorContext)}</>)

    expect(screen.getByText("Workflow lookup failed")).toBeInTheDocument()
    expect(screen.getByText("WF-999")).toBeInTheDocument()
    expect(screen.getByText("Workflow not found or inaccessible")).toBeInTheDocument()
  })

  it("omits optional sections when fields are missing", () => {
    const parsedResult = { workflow: { id: 1, state: "queued" } }
    render(<>{readWorkflowToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("WF-1")).toBeInTheDocument()
    expect(screen.queryByText("Steps")).not.toBeInTheDocument()
    expect(screen.getByText("No steps have been created for this Workflow.")).toBeInTheDocument()
  })

  it("falls back to null for a malformed payload (missing workflow object)", () => {
    expect(readWorkflowToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(readWorkflowToolCard.renderExpanded(context({ parsedResult: { oops: true } }))).toBeNull()
  })

  it("falls back to null for a non-object payload", () => {
    expect(readWorkflowToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
