import type { ToolCardExample } from "@app/pluginToolCards"
import { maintenanceToolCard } from "../jobEpicMaintenanceToolCard"

export default maintenanceToolCard("poll_job_feedback")

export const examples: ToolCardExample[] = [
  {
    id: "pending_confirmation",
    label: "Pending feedback poll",
    input: { job_id: 46 },
    parsedResult: {
      pending_confirmation_id: 29,
      pending_action_id: 29,
      state: "pending",
      message: "Poll PR feedback for JOB-46?"
    }
  },
  {
    id: "pending_without_input",
    label: "Pending feedback poll without call input",
    parsedResult: {
      pending_confirmation_id: 30,
      pending_action_id: 30,
      state: "pending",
      message: "Poll PR feedback for JOB-47?"
    }
  }
]
