import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import inspectProviderCircuitToolCard from "./inspect_provider_circuit"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "inspect_provider_circuit",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

const CLOSED_PAYLOAD = {
  provider: "claude",
  open: false,
  reason: null,
  retry_after: null,
  failure_count: 0,
  job_count: 0,
  signature: null,
  model: null,
  usage_limit: false,
  evidence: null,
  decision: { provider: "claude", open: false, reason: null, retry_after: null, failure_count: 0, job_count: 0, model: null, usage_limit: false },
  runs: [],
  evidence_records: [],
  consumers: { queued_workflows_without_runs: [], delayed_auto_retries: [] }
}

describe("inspect_provider_circuit tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(inspectProviderCircuitToolCard.toolName).toBe("inspect_provider_circuit")
  })

  it("summarizes a closed circuit in the collapsed row", () => {
    expect(inspectProviderCircuitToolCard.collapsedSummary?.(context({ parsedResult: CLOSED_PAYLOAD }))).toBe("claude: closed")
  })

  it("renders a closed circuit with an explicit empty state for Runs", () => {
    render(<>{inspectProviderCircuitToolCard.renderExpanded(context({ parsedResult: CLOSED_PAYLOAD }))}</>)
    expect(screen.getByText("closed")).toBeInTheDocument()
    expect(screen.getByText("No failed Runs in the evidence window.")).toBeInTheDocument()
  })

  it("summarizes an open circuit with blocked consumers", () => {
    const parsedResult = {
      ...CLOSED_PAYLOAD,
      open: true,
      reason: "usage limit",
      model: "claude-sonnet-5",
      usage_limit: true,
      decision: { ...CLOSED_PAYLOAD.decision, open: true, reason: "usage limit", model: "claude-sonnet-5", usage_limit: true },
      runs: [
        {
          id: 501,
          job_id: 4048,
          step_kind: "implement",
          agent_outcome: "provider_transient",
          finished_at: "2026-09-06T00:00:00Z",
          classification: { classification: "rate_limited" },
          circuit_usage_limit_candidate: true,
          circuit_retryable_candidate: false
        }
      ],
      consumers: {
        queued_workflows_without_runs: [{ workflow_id: 900, job_id: 4048, start_blocked_reason: "provider_circuit_open" }],
        delayed_auto_retries: [{ auto_retry_attempt_id: 1, job_id: 4048, retry_kind: "ci_failure", scheduled_at: "2026-09-06T01:00:00Z" }]
      }
    }

    expect(inspectProviderCircuitToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("claude: open (usage limit), 2 blocked")

    render(<>{inspectProviderCircuitToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("open")).toBeInTheDocument()
    expect(screen.getByText("claude-sonnet-5")).toBeInTheDocument()
    expect(screen.getByText("RUN-501")).toBeInTheDocument()
    const jobLinks = screen.getAllByRole("link", { name: "JOB-4048" })
    expect(jobLinks.length).toBeGreaterThan(0)
    expect(screen.getByText("rate_limited")).toBeInTheDocument()
    expect(screen.getByText("provider circuit open")).toBeInTheDocument()
    expect(screen.getByText("ci_failure")).toBeInTheDocument()
  })

  it("falls back to null for a malformed payload", () => {
    expect(inspectProviderCircuitToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(inspectProviderCircuitToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
