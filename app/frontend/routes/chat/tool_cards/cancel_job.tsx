import type { ToolCardExample } from "@app/pluginToolCards"
import { maintenanceToolCard } from "../jobEpicMaintenanceToolCard"

export default maintenanceToolCard("cancel_job")

export const examples: ToolCardExample[] = [
  {
    id: "pending_without_input",
    label: "Pending cancellation without call input",
    parsedResult: {
      pending_confirmation_id: 27,
      pending_action_id: 27,
      state: "pending",
      message: "Cancel JOB-44? Cancellation requires operator confirmation."
    }
  },
  {
    id: "bulk_pending",
    label: "Bulk cancellation",
    input: { job_ids: [44, 45, 46] },
    parsedResult: {
      pending_action_group_id: 8,
      pending_action_id: 28,
      state: "pending",
      member_count: 3,
      message: "Cancel 3 Jobs?"
    }
  }
]
