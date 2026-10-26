import type { ToolCardExample } from "@app/pluginToolCards"
import i18n from "@app/i18n"
import { maintenanceToolCard } from "../jobEpicMaintenanceToolCard"

export default maintenanceToolCard("remove_job_from_epic")

export const examples: ToolCardExample[] = [
  {
    id: "removed",
    label: i18n.t("chat:tool_card_examples.job_removed_from_epic"),
    input: { job_id: 72 },
    parsedResult: { job_id: 72, removed_from_epic_id: 73, removed_from_epic_title: "Old Epic" }
  },
  {
    id: "not_in_epic",
    label: i18n.t("chat:tool_card_examples.job_not_in_epic"),
    input: { job_id: 72 },
    resultBody: "Error: job must currently belong to an epic",
    resultError: true
  }
]
