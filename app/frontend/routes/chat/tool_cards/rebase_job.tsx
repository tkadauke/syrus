import type { ToolCardExample } from "@app/pluginToolCards"
import { maintenanceToolCard } from "../jobEpicMaintenanceToolCard"

export default maintenanceToolCard("rebase_job")

export const examples: ToolCardExample[] = [
  {
    id: "pending_confirmation",
    label: "Pending Job rebase",
    input: { job_id: 48, reason: "Refresh the branch after **main** changed." },
    parsedResult: {
      pending_confirmation_id: 32,
      pending_action_id: 32,
      state: "pending",
      reason: "Refresh the branch after **main** changed.",
      message: "Job rebase requires operator confirmation."
    }
  },
  {
    id: "failed_request",
    label: "Failed Job rebase request",
    input: { job_id: 49, reason: "Retry after the dependency landed." },
    parsedResult: { error: "A rebase is already in progress." },
    resultError: true,
    resultBody: "Error: A rebase is already in progress."
  }
]
