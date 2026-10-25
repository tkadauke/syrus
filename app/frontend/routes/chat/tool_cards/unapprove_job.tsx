import type { ToolCardExample } from "@app/pluginToolCards"
import { maintenanceToolCard } from "../jobEpicMaintenanceToolCard"
import i18n from "@app/i18n"

export default maintenanceToolCard("unapprove_job")

export const examples: ToolCardExample[] = [
  {
    id: "success",
    label: i18n.t("chat:mutation_example_unapproved_job"),
    input: { job_id: 52 },
    parsedResult: { job_id: 52, previous_state: "approved", new_state: "implemented" }
  },
  {
    id: "bulk_pending",
    label: i18n.t("chat:mutation_example_bulk_unapproval_confirmation"),
    input: { job_ids: [56, 57] },
    parsedResult: {
      pending_action_group_id: 6,
      pending_action_id: 19,
      state: "pending",
      member_count: 2,
      message: "Unapprove 2 Jobs?"
    }
  },
  {
    id: "validation_error",
    label: i18n.t("chat:mutation_example_invalid_job_state"),
    input: { job_ids: [58, 59] },
    resultBody: "Error: job must be in approved state: JOB-58, JOB-59",
    resultError: true
  }
]
