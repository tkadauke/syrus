import type { ToolCardExample } from "@app/pluginToolCards"
import { maintenanceToolCard } from "../jobEpicMaintenanceToolCard"

export default maintenanceToolCard("set_job_priority")

export const examples: ToolCardExample[] = [
  {
    id: "priority_changed",
    label: "Priority changed",
    input: { job_id: 51, priority: "urgent" },
    parsedResult: { job_id: 51, previous_priority: "medium", new_priority: "urgent" }
  },
  {
    id: "invalid_priority",
    label: "Invalid priority",
    input: { job_id: 51, priority: "immediate" },
    resultBody: "Error: priority must be urgent, high, medium, or low",
    resultError: true
  }
]
