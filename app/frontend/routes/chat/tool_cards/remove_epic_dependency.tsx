import type { ToolCardExample } from "@app/pluginToolCards"
import { maintenanceToolCard } from "../jobEpicMaintenanceToolCard"

export default maintenanceToolCard("remove_epic_dependency")

export const examples: ToolCardExample[] = [
  {
    id: "dependency_removed",
    label: "Dependency removed",
    input: { epic_id: 42, depends_on_epic_id: 41 },
    parsedResult: { epic_id: 42, depends_on: [40] }
  },
  {
    id: "no_dependencies",
    label: "No dependencies remain",
    input: { epic_id: 42, depends_on_epic_id: 41 },
    parsedResult: { epic_id: 42, depends_on: [] }
  },
  {
    id: "validation_error",
    label: "Validation error",
    input: { epic_id: 42, depends_on_epic_id: 41 },
    resultBody: "Error: Epic dependency does not exist",
    resultError: true
  }
]
