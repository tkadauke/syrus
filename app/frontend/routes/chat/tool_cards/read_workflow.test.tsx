import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
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
              { id: 9, state: "succeeded", agent_outcome: "success", agent_summary: "changed the code", started_at: "2026-01-01T00:00:00Z", finished_at: "2026-01-01T00:02:00Z", cost_usd: "0.42" }
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
    expect(screen.getByText("JOB-4221")).toBeInTheDocument()
    expect(screen.getByText("Implementing tool cards")).toBeInTheDocument()
    expect(screen.getByText("implement")).toBeInTheDocument()
    expect(screen.getAllByText("succeeded")).toHaveLength(2)
    expect(screen.getByText("RUN-9")).toBeInTheDocument()
    expect(screen.getByText("success")).toBeInTheDocument()
    expect(screen.getByText("$0.4200")).toBeInTheDocument()
    expect(screen.getByText("changed the code")).toBeInTheDocument()
  })

  it("omits optional sections when fields are missing", () => {
    const parsedResult = { workflow: { id: 1, state: "queued" } }
    render(<>{readWorkflowToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("WF-1")).toBeInTheDocument()
    expect(screen.queryByText("Steps")).not.toBeInTheDocument()
  })

  it("falls back to null for a malformed payload (missing workflow object)", () => {
    expect(readWorkflowToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(readWorkflowToolCard.renderExpanded(context({ parsedResult: { oops: true } }))).toBeNull()
  })

  it("falls back to null for a non-object payload", () => {
    expect(readWorkflowToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
