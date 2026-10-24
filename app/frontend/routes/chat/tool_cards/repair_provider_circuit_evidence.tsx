import type { ToolCardExample } from "@app/pluginToolCards"
import { pendingActionToolCard } from "../pendingActionToolCard"

// Pending-action tool card (the pending-action tool-card work). All of the parsing and
// presentation lives in ../pendingActionToolCard so the whole family stays
// consistent; this file only binds it to one MCP tool name.
const repairProviderCircuitEvidenceToolCard = pendingActionToolCard("repair_provider_circuit_evidence", {
  inputFields: [
    { key: "evidence_type", format: "badge" },
    { key: "evidence_id", format: "entity", entityKind: "artifact" },
    { key: "evidence_ids", format: "entity_list", entityKind: "artifact" },
    { key: "repair_status", format: "badge" },
    { key: "reason", format: "markdown" }
  ],
  observedSummary: true
})

export const examples: ToolCardExample[] = [
  {
    id: "single_pending",
    label: "Single repair pending",
    description: "Shows the evidence type and repair status badges, copyable id, Markdown reason, and observed evidence snapshot.",
    input: {
      evidence_type: "provider_availability_evidence",
      evidence_id: 71,
      repair_status: "false_positive",
      reason: "The probe used **stale credentials** after the provider account was rotated."
    },
    parsedResult: {
      pending_action_id: 501,
      pending_confirmation_id: 501,
      state: "pending",
      reason: "The probe used **stale credentials** after the provider account was rotated.",
      message: "Mark provider_availability_evidence #71 as false_positive for provider-circuit decisions?",
      observed: { evidence_id: 71, status: "warning", source: "usage_probe", observed_at: "2026-10-22T12:00:00Z" }
    }
  },
  {
    id: "group_confirmed",
    label: "Grouped repair confirmed",
    description: "Exercises grouped ids, member count, confirmed state, responsive wrapping, and multiple observed snapshots.",
    input: {
      evidence_type: "run_failure_classification",
      evidence_ids: [81, 82, 83],
      repair_status: "transient",
      reason: "All classifications came from the same **short provider incident** and should be reviewed together."
    },
    parsedResult: {
      pending_action_group_id: 91,
      pending_action_id: 502,
      pending_confirmation_id: 502,
      state: "confirmed",
      member_count: 3,
      message: "Mark 3 run_failure_classification evidence items as transient for provider-circuit decisions?",
      observed: [
        { evidence_id: 81, status: "provider_transient", source: "run_failure_classification", observed_at: "2026-10-22T12:01:00Z" },
        { evidence_id: 82, status: "provider_transient", source: "run_failure_classification", observed_at: "2026-10-22T12:02:00Z" },
        { evidence_id: 83, status: "provider_transient", source: "run_failure_classification", observed_at: "2026-10-22T12:03:00Z" }
      ]
    }
  },
  {
    id: "rejected",
    label: "Repair rejected",
    input: {
      evidence_type: "run_failure_classification",
      evidence_id: 84,
      repair_status: "inconclusive",
      reason: "The available diagnostics do not establish a provider failure."
    },
    parsedResult: {
      pending_action_id: 503,
      pending_confirmation_id: 503,
      state: "rejected",
      message: "Mark run_failure_classification #84 as inconclusive for provider-circuit decisions?",
      observed: { evidence_id: 84, status: "unknown", source: "run_failure_classification", observed_at: "2026-10-22T12:04:00Z" }
    }
  },
  {
    id: "tool_error",
    label: "Tool error",
    description: "Keeps the requested repair parameters visible when the tool rejects the request.",
    input: {
      evidence_type: "provider_availability_evidence",
      evidence_id: 999,
      repair_status: "false_positive",
      reason: "The evidence was superseded by a later successful probe."
    },
    parsedResult: { error: "Evidence not found: provider_availability_evidence 999" },
    resultError: true
  }
]

export default repairProviderCircuitEvidenceToolCard
