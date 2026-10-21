import type { ToolCardExample } from "@app/pluginToolCards"
import { maintenanceToolCard } from "../jobEpicMaintenanceToolCard"

export default maintenanceToolCard("add_epic_dependency")

export const examples: ToolCardExample[] = [
  {
    id: "dependency_added",
    label: "Dependency added",
    input: { epic_id: 42, depends_on_epic_id: 41 },
    parsedResult: { epic_id: 42, depends_on: [40, 41] }
  },
  {
    id: "validation_error",
    label: "Validation error",
    input: { epic_id: 42, depends_on_epic_id: 42 },
    resultBody: "Error: Epic cannot depend on itself",
    resultError: true
  }
]
