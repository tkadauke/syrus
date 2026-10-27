import type { ToolCardExample } from "@app/pluginToolCards"
import i18n from "@app/i18n"
import { maintenanceToolCard } from "../jobEpicMaintenanceToolCard"

const forceFailJobCard = maintenanceToolCard("force_fail_job")

export default {
  ...forceFailJobCard,
  toolName: "force_fail_job",
  // The structured card renders the reason as Markdown in both single and bulk results.
  argumentSummary: (_input?: Record<string, unknown>) => ""
}

export const examples: ToolCardExample[] = [
  {
    id: "pending_confirmation",
    get label() {
      return i18n.t("chat:tool_card_examples.pending_force_fail_confirmation")
    },
    input: { job_id: 73, reason: "The workflow is **irrecoverably** stuck." },
    parsedResult: {
      pending_confirmation_id: 41,
      pending_action_id: 41,
      state: "pending",
      job_id: 73,
      previous_state: "running",
      new_state: "failed",
      reason: "The workflow is **irrecoverably** stuck.",
      message: "Force fail JOB-73?"
    }
  },
  {
    id: "bulk_pending",
    get label() {
      return i18n.t("chat:tool_card_examples.bulk_force_fail_confirmation")
    },
    input: { job_ids: [73, 74, 75], reason: "All three runs share the same **fatal** failure." },
    parsedResult: {
      pending_action_group_id: 12,
      pending_action_id: 42,
      state: "pending",
      member_count: 3,
      message: "Force fail 3 Jobs?"
    }
  },
  {
    id: "invalid_state",
    get label() {
      return i18n.t("chat:tool_card_examples.job_cannot_be_force_failed")
    },
    input: { job_id: 76, reason: "No longer recoverable." },
    resultBody: "Error: JOB-76 is closed and cannot be force-failed.",
    resultError: true
  }
]
