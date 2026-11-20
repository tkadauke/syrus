import type { ToolCardExample } from "@app/pluginToolCards"
import { maintenanceToolCard } from "../jobEpicMaintenanceToolCard"

export default maintenanceToolCard("replace_job_dependency")
export const examples: ToolCardExample[] = [
  {
    id: "replacement",
    label: "Dependency replaced",
    input: { job_id: 50, remove_dependency_job_id: 49, add_dependency_job_id: 48 },
    parsedResult: { job_id: 50, depends_on_job_ids: [48], depends_on_epic_ids: [] }
  }
]
