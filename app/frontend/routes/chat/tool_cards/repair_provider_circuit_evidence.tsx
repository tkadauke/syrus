import i18n from "../../../i18n"
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
    label: i18n.t("chat:ops_single_repair_pending_ee45c8"),
    description: i18n.t("chat:ops_shows_the_evidence_type_and_repair_status_badges_2c026a"),
    input: {
      evidence_type: "provider_availability_evidence",
      evidence_id: 71,
      repair_status: "false_positive",
      reason: i18n.t("chat:ops_the_probe_used_stale_credentials_after_the_provider_acco_436cce")
    },
    parsedResult: {
      pending_action_id: 501,
      pending_confirmation_id: 501,
      state: "pending",
      reason: i18n.t("chat:ops_the_probe_used_stale_credentials_after_the_provider_acco_436cce"),
      message: "Mark provider_availability_evidence #71 as false_positive for provider-circuit decisions?",
      observed: { evidence_id: 71, status: "warning", source: "usage_probe", observed_at: "2026-10-22T12:00:00Z" }
    }
  },
  {
    id: "group_confirmed",
    label: i18n.t("chat:ops_grouped_repair_confirmed_478273"),
    description: i18n.t("chat:ops_exercises_grouped_ids_member_count_confirmed_sta_4017c6"),
    input: {
      evidence_type: "run_failure_classification",
      evidence_ids: [81, 82, 83],
      repair_status: "transient",
      reason: i18n.t("chat:ops_all_classifications_came_from_the_same_short_provider_in_1b9d34")
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
    label: i18n.t("chat:ops_repair_rejected_ed4784"),
    input: {
      evidence_type: "run_failure_classification",
      evidence_id: 84,
      repair_status: "inconclusive",
      reason: i18n.t("chat:ops_the_available_diagnostics_do_not_establish_a_provider_fa_a15d7e")
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
    label: i18n.t("chat:ops_tool_error_7e2d1e"),
    description: i18n.t("chat:ops_keeps_the_requested_repair_parameters_visible_wh_223337"),
    input: {
      evidence_type: "provider_availability_evidence",
      evidence_id: 999,
      repair_status: "false_positive",
      reason: i18n.t("chat:ops_the_evidence_was_superseded_by_a_later_successful_probe_52c471")
    },
    parsedResult: { error: "Evidence not found: provider_availability_evidence 999" },
    resultError: true
  }
]

export default repairProviderCircuitEvidenceToolCard
