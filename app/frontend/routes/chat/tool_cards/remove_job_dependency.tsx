import type { ToolCardExample } from "@app/pluginToolCards"
import { maintenanceToolCard } from "../jobEpicMaintenanceToolCard"

export default maintenanceToolCard("remove_job_dependency")

export const examples: ToolCardExample[] = [
  {
    id: "job_dependency_removed",
    label: "Job dependency removed",
    input: { job_id: 50, depends_on_job_id: 49 },
    parsedResult: { job_id: 50, depends_on_job_ids: [48], depends_on_epic_ids: [12] }
  },
  {
    id: "epic_dependency_removed_no_dependencies",
    label: "Epic dependency removed with none remaining",
    input: { job_id: 50, depends_on_epic_id: 12 },
    parsedResult: { job_id: 50, depends_on_job_ids: [], depends_on_epic_ids: [] }
  },
  {
    id: "validation_error",
    label: "Validation error",
    input: { job_id: 50, depends_on_job_id: 49 },
    resultBody: "Error: Job dependency does not exist",
    resultError: true
  }
]
