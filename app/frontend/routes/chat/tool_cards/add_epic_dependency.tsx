import type { ToolCardExample } from "@app/pluginToolCards"
import { maintenanceToolCard } from "../jobEpicMaintenanceToolCard"
import i18n from "@app/i18n"

export default maintenanceToolCard("add_epic_dependency")

export const examples: ToolCardExample[] = [
  {
    id: "dependency_added",
    label: i18n.t("chat:mutation_example_dependency_added"),
    input: { epic_id: 42, depends_on_epic_id: 41 },
    parsedResult: { epic_id: 42, depends_on: [40, 41] }
  },
  {
    id: "validation_error",
    label: i18n.t("chat:tool_card_example_validation_error"),
    input: { epic_id: 42, depends_on_epic_id: 42 },
    resultBody: "Error: Epic cannot depend on itself",
    resultError: true
  }
]
