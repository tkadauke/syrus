import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import { redactToolCardValue } from "@app/toolCardSecurity"
import { normalizedToolCardParsedResult, normalizedToolName } from "../toolRendering"
import repairProviderCircuitEvidenceToolCard, { examples } from "./repair_provider_circuit_evidence"

const RESULT = {
  pending_action_id: 501,
  pending_confirmation_id: 501,
  state: "pending",
  message: "Mark provider availability evidence?",
  observed: { evidence_id: 71, status: "warning", source: "usage_probe", observed_at: "2026-10-22T12:00:00Z" }
}

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "repair_provider_circuit_evidence",
    input: {
      evidence_type: "provider_availability_evidence",
      evidence_id: 71,
      repair_status: "false_positive",
      reason: "Probe contained **stale credentials**."
    },
    resultBody: "",
    resultError: false,
    parsedResult: RESULT,
    ...overrides
  }
}

describe("repair_provider_circuit_evidence tool card", () => {
  it("registers visual catalog examples for the changed states", () => {
    expect(examples.map((example) => example.id)).toEqual(["single_pending", "group_confirmed", "rejected", "tool_error"])
  })

  it("registers the raw sidecar name and renders every single-repair field", () => {
    expect(normalizedToolName("mcp__syrus-chat-sidecar__repair_provider_circuit_evidence")).toBe(repairProviderCircuitEvidenceToolCard.toolName)

    render(<>{repairProviderCircuitEvidenceToolCard.renderExpanded(context())}</>)

    expect(screen.getByText("provider_availability_evidence")).toBeInTheDocument()
    expect(screen.getAllByText("71").length).toBeGreaterThan(0)
    expect(screen.getAllByRole("button", { name: /copy 71 to clipboard/i })).toHaveLength(2)
    expect(screen.getByText("false_positive")).toBeInTheDocument()
    expect(screen.getByText(/stale credentials/)).toBeInTheDocument()
    expect(screen.getByText("warning")).toBeInTheDocument()
    expect(screen.getByText("usage_probe")).toBeInTheDocument()
    expect(screen.getByText("2026-10-22T12:00:00Z")).toBeInTheDocument()
  })

  it.each([
    ["direct", (payload: object) => payload],
    ["structured content", (payload: object) => ({ structured_content: payload, content: [] })],
    ["text content", (payload: object) => ({ structured_content: null, content: [{ type: "text", text: JSON.stringify(payload) }] })]
  ])("normalizes %s result envelopes", (_name, envelope) => {
    const parsedResult = normalizedToolCardParsedResult(envelope(RESULT))
    render(<>{repairProviderCircuitEvidenceToolCard.renderExpanded(context({ parsedResult }))}</>)
    expect(screen.getByText("Pending action #501")).toBeInTheDocument()
    expect(screen.getByText("warning")).toBeInTheDocument()
  })

  it.each(["pending", "confirmed", "rejected"])("renders the %s state", (state) => {
    render(<>{repairProviderCircuitEvidenceToolCard.renderExpanded(context({ parsedResult: { ...RESULT, state } }))}</>)
    expect(screen.getByText(state)).toBeInTheDocument()
  })

  it("renders grouped ids, group id, member count, and observed snapshots", () => {
    render(
      <>
        {repairProviderCircuitEvidenceToolCard.renderExpanded(
          context({
            input: {
              evidence_type: "run_failure_classification",
              evidence_ids: [81, 82],
              repair_status: "transient",
              reason: "Shared **provider incident**."
            },
            parsedResult: {
              ...RESULT,
              pending_action_group_id: 91,
              member_count: 2,
              observed: [
                { evidence_id: 81, status: "provider_transient", source: "run_failure_classification", observed_at: "2026-10-22T12:01:00Z" },
                { evidence_id: 82, status: "provider_transient", source: "run_failure_classification", observed_at: "2026-10-22T12:02:00Z" }
              ]
            }
          })
        )}
      </>
    )

    expect(screen.getByText("Pending action group #91")).toBeInTheDocument()
    expect(screen.getByText("2 actions")).toBeInTheDocument()
    expect(screen.getAllByRole("button", { name: /copy 8[12] to clipboard/i })).toHaveLength(4)
    expect(screen.getAllByText("provider_transient")).toHaveLength(2)
  })

  it("keeps inputs visible for errors and passes values through redaction", () => {
    const input = redactToolCardValue({
      evidence_type: "run_failure_classification",
      evidence_id: 81,
      repair_status: "inconclusive",
      reason: "Authorization: Bearer abcdefghijklmnopqrstuvwxyz"
    }) as Record<string, unknown>
    const parsedResult = redactToolCardValue({ error: "Repair failed for token=abcdefghijklmnopqrstuvwxyz" })

    render(<>{repairProviderCircuitEvidenceToolCard.renderExpanded(context({ input, parsedResult, resultError: true }))}</>)

    expect(screen.getByText("failed")).toBeInTheDocument()
    expect(screen.getByText("inconclusive")).toBeInTheDocument()
    expect(screen.getAllByText(/\[redacted\]/).length).toBeGreaterThan(0)
    expect(screen.queryByText(/abcdefghijklmnopqrstuvwxyz/)).not.toBeInTheDocument()
  })
})
