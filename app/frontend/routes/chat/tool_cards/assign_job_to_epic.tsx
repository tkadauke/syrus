import type { ToolCardExample } from "@app/pluginToolCards"
import { maintenanceToolCard } from "../jobEpicMaintenanceToolCard"

export default maintenanceToolCard("assign_job_to_epic")

export const examples: ToolCardExample[] = [
  {
    id: "assigned",
    label: "Job assigned to Epic",
    input: { job_id: 74, epic_id: 75 },
    parsedResult: { job_id: 74, epic_id: 75, epic_title: "Tool card polish" }
  },
  {
    id: "archived_epic",
    label: "Archived Epic error",
    input: { job_id: 74, epic_id: 76 },
    resultBody: "Error: epic must not be archived",
    resultError: true
  }
]
