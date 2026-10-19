import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import { normalizedToolCardParsedResult, normalizedToolName } from "../toolRendering"
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
    expect(normalizedToolName("mcp__syrus-chat-sidecar__inspect_provider_circuit")).toBe(inspectProviderCircuitToolCard.toolName)
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
      signature: { model: "claude-sonnet-5" },
      evidence: { source: "recent failures" },
      decision: {
        ...CLOSED_PAYLOAD.decision,
        open: true,
        reason: "usage limit",
        model: "claude-sonnet-5",
        usage_limit: true,
        signature: { model: "claude-sonnet-5" },
        evidence: { source: "recent failures" }
      },
      runs: [
        {
          id: 501,
          job_id: 4048,
          job_slug: "provider-card",
          workflow_id: 900,
          step_id: 77,
          step_kind: "implement",
          trigger_kind: "initial",
          agent_provider: "claude",
          agent_outcome: "provider_transient",
          extracted_model: "claude-sonnet-5",
          retry_after: "2026-09-06T01:00:00Z",
          finished_at: "2026-09-06T00:00:00Z",
          diagnostic: { id: 31, error_class: "ProviderError", error_message: "retry later" },
          classification: {
            id: 41,
            classification: "rate_limited",
            confidence: 0.9,
            retryable: true,
            reason: "Provider said **slow down**",
            diagnostic_summary: "A long diagnostic",
            classified_at: "2026-09-06T00:01:00Z",
            classifier_inputs: { status: 429 },
            repair: { status: "inconclusive" }
          },
          circuit_usage_limit_candidate: true,
          circuit_retryable_candidate: true
        }
      ],
      evidence_records: [
        {
          id: 61,
          status: "warning",
          source: "usage_probe",
          observed_at: "2026-09-06T00:02:00Z",
          provider: "claude",
          account_id: "acct-1",
          model: "claude-sonnet-5",
          run_id: 501,
          chat_session_id: 12,
          chat_message_id: 13,
          http_status: 429,
          details: { note: "near limit" },
          repair: { status: "transient" }
        }
      ],
      consumers: {
        queued_workflows_without_runs: [
          {
            workflow_id: 901,
            job_id: 4048,
            job_slug: "provider-card",
            trigger_kind: "pr_feedback",
            start_blocked_reason: "provider_circuit_open",
            start_blocked_details: { provider: "claude" },
            next_check_at: "2026-09-06T01:00:00Z"
          }
        ],
        delayed_auto_retries: [
          {
            auto_retry_attempt_id: 1,
            job_id: 4048,
            job_slug: "provider-card",
            workflow_id: 900,
            run_id: 501,
            retry_kind: "ci_failure",
            scheduled_at: "2026-09-06T01:00:00Z",
            failure_classification: "rate_limited"
          }
        ]
      }
    }

    expect(inspectProviderCircuitToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("claude: open (usage limit), 2 blocked")

    render(<>{inspectProviderCircuitToolCard.renderExpanded(context({ input: { provider: "claude", user_id: 8 }, parsedResult }))}</>)

    expect(screen.getByText("open")).toBeInTheDocument()
    expect(screen.getAllByText("claude-sonnet-5").length).toBeGreaterThan(0)
    expect(screen.getAllByText("RUN-501").length).toBeGreaterThan(0)
    expect(screen.getAllByText("WF-900").length).toBeGreaterThan(0)
    const jobLinks = screen.getAllByRole("link", { name: "JOB-4048" })
    expect(jobLinks.length).toBeGreaterThan(0)
    expect(screen.getByText("rate_limited")).toBeInTheDocument()
    expect(screen.getByText("provider_circuit_open")).toBeInTheDocument()
    expect(screen.getByText("ci_failure")).toBeInTheDocument()
    expect(screen.getByText("Classification 41")).toBeInTheDocument()
    expect(screen.getByText("Evidence 61")).toBeInTheDocument()
    expect(screen.getByText("pr_feedback")).toBeInTheDocument()
    expect(screen.getByText("acct-1")).toBeInTheDocument()
    expect(screen.getByText("8")).toBeInTheDocument()
  })

  it.each([
    ["direct", (payload: object) => payload],
    ["structured content", (payload: object) => ({ structured_content: payload, content: [] })],
    ["text content", (payload: object) => ({ structured_content: null, content: [{ type: "text", text: JSON.stringify(payload) }] })]
  ])("renders %s MCP results", (_name, envelope) => {
    const parsedResult = normalizedToolCardParsedResult(envelope(CLOSED_PAYLOAD))
    render(<>{inspectProviderCircuitToolCard.renderExpanded(context({ parsedResult }))}</>)
    expect(screen.getByText("No failed Runs in the evidence window.")).toBeInTheDocument()
  })

  it("redacts secrets in diagnostic and classifier previews", () => {
    const parsedResult = {
      ...CLOSED_PAYLOAD,
      runs: [
        {
          id: 1,
          diagnostic: { error_message: "Authorization: Bearer abcdefghijklmnopqrstuvwxyz" },
          classification: { classification: "turn_failed", classifier_inputs: { api_key: "sk-abcdefghijklmnopqrstuvwxyz" } }
        }
      ]
    }
    render(<>{inspectProviderCircuitToolCard.renderExpanded(context({ parsedResult }))}</>)
    expect(screen.getAllByText(/\[redacted\]/).length).toBeGreaterThan(0)
    expect(screen.queryByText(/abcdefghijklmnopqrstuvwxyz/)).not.toBeInTheDocument()
  })

  it("falls back to null for a malformed payload", () => {
    expect(inspectProviderCircuitToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(inspectProviderCircuitToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
    expect(inspectProviderCircuitToolCard.renderExpanded(context({ parsedResult: { error: "unavailable" }, resultError: true }))).toBeNull()
  })
})
