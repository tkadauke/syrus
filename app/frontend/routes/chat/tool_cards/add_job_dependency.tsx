import type { ToolCardExample } from "@app/pluginToolCards"
import { maintenanceToolCard } from "../jobEpicMaintenanceToolCard"

export default maintenanceToolCard("add_job_dependency")

export const examples: ToolCardExample[] = [
  {
    id: "job_and_epic_dependencies",
    label: "Job and Epic dependencies",
    input: { job_id: 50, depends_on_job_id: 49 },
    parsedResult: {
      job_id: 50,
      depends_on_job_ids: [49],
      depends_on_epic_ids: [12],
      dependencies: [
        { id: 101, depends_on_job_id: 49, satisfaction_mode: "success", required_deployment_stage_name: null },
        { id: 102, epic_id: 12, satisfaction_mode: "deployment_stage", required_deployment_stage_name: "production" }
      ]
    }
  },
  {
    id: "validation_error",
    label: "Validation error",
    input: { job_id: 50, depends_on_job_id: 50 },
    resultBody: "Error: Job cannot depend on itself",
    resultError: true
  },
  {
    id: "empty_dependencies",
    label: "No current dependencies",
    input: { job_id: 50 },
    parsedResult: { job_id: 50, depends_on_job_ids: [], depends_on_epic_ids: [], dependencies: [] }
  }
]
