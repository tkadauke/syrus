import type { ToolCardExample } from "@app/pluginToolCards"
import { maintenanceToolCard } from "../jobEpicMaintenanceToolCard"

export default maintenanceToolCard("close_job_successfully")

export const examples: ToolCardExample[] = [
  {
    id: "pending_confirmation",
    label: "Pending close with PR comment",
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
      message: "Successful Job close requires operator confirmation."
    }
  },
  {
    id: "bulk_pending",
    label: "Bulk close confirmation",
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
    label: "Invalid closure error",
    input: { job_id: 84, closure_reason: "no_changes", comment: "This should not be posted." },
    resultBody: "Error: JOB-84 cannot be closed from running.",
    resultError: true
  }
]
