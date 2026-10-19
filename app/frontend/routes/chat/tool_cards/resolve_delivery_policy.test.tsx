import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import { normalizedToolCardParsedResult, normalizedToolName } from "../toolRendering"
import resolveDeliveryPolicyToolCard from "./resolve_delivery_policy"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return { toolName: "resolve_delivery_policy", resultBody: "", resultError: false, parsedResult: null, ...overrides }
}

function normalizedContext(toolName: string, parsedResult: unknown, overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return context({ toolName: normalizedToolName(toolName), parsedResult: normalizedToolCardParsedResult(parsedResult), ...overrides })
}

describe("resolve_delivery_policy tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(resolveDeliveryPolicyToolCard.toolName).toBe("resolve_delivery_policy")
  })

  it("summarizes the collapsed row with the resolved track and job", () => {
    const parsedResult = { repository: "tkadauke/syrus", job_id: 4225, delivery_track: "staging" }
    expect(resolveDeliveryPolicyToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("Track: staging for JOB-4225")
  })

  it("falls back to the default track label when unset", () => {
    const parsedResult = { repository: "tkadauke/syrus" }
    expect(resolveDeliveryPolicyToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("Track: default")
  })

  it("renders approval, promotion/hotfix-sync/upstream-export toggles, and ref movement actions", () => {
    const parsedResult = {
      repository: "tkadauke/syrus",
      job_id: 4225,
      delivery_track: "staging",
      job_landing_branch: "staging-branch",
      review_grade_phase: "review",
      landing_grade_phase: "landing",
      approval: { configured: true, job_approval_satisfied: false, requires_operator_approval_for_promotion: true },
      promotion: { enabled: true, mode: "auto" },
      hotfix_sync: { enabled: false, mode: null },
      upstream_export: { enabled: true, mode: "manual", after_local_approval: true },
      ref_movement_actions: {
        send_job_upstream: { enabled: true, mode: "auto", grade_phases: ["review"] }
      }
    }

    render(<>{resolveDeliveryPolicyToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByRole("link", { name: "tkadauke/syrus" })).toHaveAttribute("href", "https://github.com/tkadauke/syrus")
    expect(screen.getByRole("link", { name: "JOB-4225" })).toHaveAttribute("href", "/jobs/4225")
    expect(screen.getByText("staging")).toBeInTheDocument()
    expect(screen.getByText("staging-branch")).toHaveClass("break-all", "sm:truncate")
    expect(screen.getByText("approval: configured")).toBeInTheDocument()
    expect(screen.getByText("job approval: pending")).toBeInTheDocument()
    expect(screen.getByText("promotion approval: operator required")).toBeInTheDocument()
    expect(screen.getByText("promotion: on (auto)")).toBeInTheDocument()
    expect(screen.getByText("hotfix sync: off")).toBeInTheDocument()
    expect(screen.getByText("upstream export: on (manual)")).toBeInTheDocument()
    expect(screen.getByText("export after local approval: yes")).toBeInTheDocument()
    expect(screen.getByText("1 ref movement action")).toBeInTheDocument()
    expect(screen.getByText("dispatch_ref_movement_action")).toBeInTheDocument()
  })

  it("uses shared normalization for Codex text and structured-content envelopes", () => {
    const payload = { repository: "tkadauke/syrus", job_id: 4225, delivery_track: "staging" }
    const textEnvelope = { content: [{ type: "text", text: JSON.stringify(payload) }], structured_content: null }
    const structuredEnvelope = { content: [{ type: "text", text: "ignored" }], structured_content: payload }

    expect(resolveDeliveryPolicyToolCard.collapsedSummary?.(normalizedContext("mcp__syrus__resolve_delivery_policy", textEnvelope))).toBe(
      "Track: staging for JOB-4225"
    )
    expect(resolveDeliveryPolicyToolCard.collapsedSummary?.(normalizedContext("mcp__another_server__resolve_delivery_policy", structuredEnvelope))).toBe(
      "Track: staging for JOB-4225"
    )
  })

  it("renders normalized MCP errors with useful recovery context", () => {
    const envelope = { content: [{ type: "text", text: "Error: no repository attached" }], structured_content: null }
    const toolContext = normalizedContext("mcp__syrus__resolve_delivery_policy", envelope, { resultError: true, resultBody: JSON.stringify(envelope) })

    expect(resolveDeliveryPolicyToolCard.collapsedSummary?.(toolContext)).toBe("Delivery policy resolution failed: no repository attached")
    render(<>{resolveDeliveryPolicyToolCard.renderExpanded(toolContext)}</>)
    expect(screen.getByText("Delivery policy resolution failed")).toBeInTheDocument()
    expect(screen.getByText("no repository attached")).toBeInTheDocument()
  })

  it("renders a repository-only policy without inventing job-specific values", () => {
    const parsedResult = {
      repository: "tkadauke/syrus",
      approval: { configured: false, requires_operator_approval_for_promotion: false },
      upstream_export: { enabled: false, mode: null, after_local_approval: false },
      ref_movement_actions: {}
    }

    render(<>{resolveDeliveryPolicyToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.queryByText(/^JOB-/)).not.toBeInTheDocument()
    expect(screen.getByText("approval: not configured")).toBeInTheDocument()
    expect(screen.getByText("promotion approval: not required")).toBeInTheDocument()
    expect(screen.getByText("export after local approval: no")).toBeInTheDocument()
    expect(screen.queryByText(/ref movement action/)).not.toBeInTheDocument()
  })

  it("falls back to null for a malformed payload", () => {
    expect(resolveDeliveryPolicyToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(resolveDeliveryPolicyToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
