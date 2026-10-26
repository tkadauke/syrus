import type { ToolCardExample } from "@app/pluginToolCards"
import { maintenanceToolCard } from "../jobEpicMaintenanceToolCard"
import i18n from "@app/i18n"

export default maintenanceToolCard("remove_job_from_epic")

export const examples: ToolCardExample[] = [
  {
    id: "removed",
    get label() {
      return i18n.t("chat:mutation_example_job_removed_from_epic")
    },
    input: { job_id: 72 },
    parsedResult: { job_id: 72, removed_from_epic_id: 73, removed_from_epic_title: "Old Epic" }
  },
  {
    id: "not_in_epic",
    get label() {
      return i18n.t("chat:mutation_example_job_not_in_epic")
    },
    input: { job_id: 72 },
    resultBody: "Error: job must currently belong to an epic",
    resultError: true
  }
]
