import type { ToolCardExample } from "@app/pluginToolCards"
import { maintenanceToolCard } from "../jobEpicMaintenanceToolCard"

export default maintenanceToolCard("remove_job_from_epic")

export const examples: ToolCardExample[] = [
  {
    id: "removed",
    label: "Job removed from Epic",
    input: { job_id: 72 },
    parsedResult: { job_id: 72, removed_from_epic_id: 73, removed_from_epic_title: "Old Epic" }
  },
  {
    id: "not_in_epic",
    label: "Job is not in an Epic",
    input: { job_id: 72 },
    resultBody: "Error: job must currently belong to an epic",
    resultError: true
  }
]
