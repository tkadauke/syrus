import type { ToolCardExample } from "@app/pluginToolCards"
import i18n from "@app/i18n"
import { maintenanceToolCard } from "../jobEpicMaintenanceToolCard"

export default maintenanceToolCard("update_epic")

const sampleTitle = i18n.t("chat:mutation_example_epic_title")
const longDescription = `## ${i18n.t("chat:mutation_example_updated_scope")}\n\n${`${i18n.t("chat:mutation_example_epic_description_sentence")} `.repeat(10)}`
const attemptedDescription = i18n.t("chat:mutation_example_attempted_epic_description")

export const examples: ToolCardExample[] = [
  {
    id: "title_and_description_updated",
    get label() {
      return i18n.t("chat:mutation_example_title_and_description_updated")
    },
    input: { epic_id: 71, title: sampleTitle, description: longDescription },
    parsedResult: { epic_id: 71, title: sampleTitle, description: longDescription, state: "ready" }
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
      return i18n.t("chat:mutation_example_empty_epic_description_failed")
    },
    input: { epic_id: 72, description: "" },
    resultBody: "Error: archived Epics cannot be updated",
    resultError: true
  }
]
