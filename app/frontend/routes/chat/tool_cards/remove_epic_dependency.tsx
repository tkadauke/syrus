import type { ToolCardExample } from "@app/pluginToolCards"
import i18n from "../../../i18n"
import { maintenanceToolCard } from "../jobEpicMaintenanceToolCard"

export default maintenanceToolCard("remove_epic_dependency")

export const examples: ToolCardExample[] = [
  {
    id: "dependency_removed",
    label: i18n.t("chat:tool_card_examples.dependency_removed"),
    input: { epic_id: 42, depends_on_epic_id: 41 },
    parsedResult: { epic_id: 42, depends_on: [40] }
  },
  {
    id: "no_dependencies",
    label: i18n.t("chat:tool_card_examples.no_dependencies_remain"),
    input: { epic_id: 42, depends_on_epic_id: 41 },
    parsedResult: { epic_id: 42, depends_on: [] }
  },
  {
    id: "validation_error",
    label: i18n.t("chat:tool_card_examples.validation_error"),
    input: { epic_id: 42, depends_on_epic_id: 41 },
    resultBody: "Error: Epic dependency does not exist",
    resultError: true
  }
]
