import type { ToolCardExample } from "@app/pluginToolCards"
import i18n from "../../../i18n"
import { maintenanceToolCard } from "../jobEpicMaintenanceToolCard"

export default maintenanceToolCard("close_job_successfully")

export const examples: ToolCardExample[] = [
  {
    id: "pending_confirmation",
    label: i18n.t("chat:tool_card_examples.pending_close_with_comment"),
    input: {
      job_id: 80,
      closure_reason: "no_changes",
      comment: `## Closing note\n\nNo implementation is needed. ${"The existing behavior already covers the request. ".repeat(8)}`
    },
    parsedResult: {
      pending_confirmation_id: 15,
      pending_action_id: 15,
      state: "pending",
      job_id: 80,
      closure_reason: "no_changes",
      message: i18n.t("chat:tool_card_examples.close_confirmation_required")
    }
  },
  {
    id: "bulk_pending",
    label: i18n.t("chat:tool_card_examples.bulk_close_confirmation"),
    input: { job_ids: [81, 82, 83], closure_reason: "duplicate", comment: "Closing in favor of **JOB-40**." },
    parsedResult: {
      pending_action_group_id: 9,
      pending_action_id: 16,
      state: "pending",
      member_count: 3,
      message: "Close 3 Jobs as duplicate?"
    }
  },
  {
    id: "validation_error",
    label: i18n.t("chat:tool_card_examples.invalid_closure_error"),
    input: { job_id: 84, closure_reason: "no_changes", comment: "This should not be posted." },
    resultBody: "Error: JOB-84 cannot be closed from running.",
    resultError: true
  }
]
