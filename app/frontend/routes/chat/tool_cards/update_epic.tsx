import type { ToolCardExample } from "@app/pluginToolCards"
import i18n from "@app/i18n"
import { maintenanceToolCard } from "../jobEpicMaintenanceToolCard"

export default maintenanceToolCard("update_epic")

const longDescription = `## Updated scope\n\n${"This Epic now covers **responsive** tool cards with linked details. ".repeat(10)}`

export const examples: ToolCardExample[] = [
  {
    id: "title_and_description_updated",
    label: i18n.t("chat:tool_card_update_example_title_description"),
    input: { epic_id: 71, title: i18n.t("chat:tool_card_update_epic_example_title"), description: longDescription },
    parsedResult: { epic_id: 71, title: i18n.t("chat:tool_card_update_epic_example_title"), description: longDescription, state: "ready" }
  },
  {
    id: "update_failed",
    label: i18n.t("chat:tool_card_update_epic_example_failed"),
    input: { epic_id: 71, title: "", description: i18n.t("chat:tool_card_update_example_attempted_description") },
    resultBody: "Error: title cannot be blank",
    resultError: true
  },
  {
    id: "empty_description_failed",
    label: i18n.t("chat:tool_card_update_epic_example_empty_description"),
    input: { epic_id: 72, description: "" },
    resultBody: "Error: archived Epics cannot be updated",
    resultError: true
  }
]
