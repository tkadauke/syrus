import type { ToolCardExample } from "@app/pluginToolCards"
import { maintenanceToolCard } from "../jobEpicMaintenanceToolCard"
import i18n from "@app/i18n"

export default maintenanceToolCard("update_epic")

const longDescription = `## Updated scope\n\n${"This Epic now covers **responsive** tool cards with linked details. ".repeat(10)}`
const updatedTitle = "Improve maintenance cards"
const attemptedDescription = "Keep the **attempted** description visible."

export const examples: ToolCardExample[] = [
  {
    id: "title_and_description_updated",
    get label() {
      return i18n.t("chat:mutation_example_title_and_description_updated")
    },
    input: { epic_id: 71, title: updatedTitle, description: longDescription },
    parsedResult: { epic_id: 71, title: updatedTitle, description: longDescription, state: "ready" }
  },
  {
    id: "update_failed",
    get label() {
      return i18n.t("chat:mutation_example_epic_update_failed")
    },
    input: { epic_id: 71, title: "", description: attemptedDescription },
    resultBody: "Error: title cannot be blank",
    resultError: true
  },
  {
    id: "empty_description_failed",
    get label() {
      return i18n.t("chat:mutation_example_empty_description_update_failed")
    },
    input: { epic_id: 72, description: "" },
    resultBody: "Error: archived Epics cannot be updated",
    resultError: true
  }
]
