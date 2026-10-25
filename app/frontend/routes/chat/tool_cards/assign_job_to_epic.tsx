import type { ToolCardExample } from "@app/pluginToolCards"
import i18n from "@app/i18n"
import { maintenanceToolCard } from "../jobEpicMaintenanceToolCard"

export default maintenanceToolCard("assign_job_to_epic")

export const examples: ToolCardExample[] = [
  {
    id: "assigned",
    label: i18n.t("chat:tool_card_assign_job_to_epic_example_assigned"),
    input: { job_id: 74, epic_id: 75 },
    parsedResult: { job_id: 74, epic_id: 75, epic_title: "Tool card polish" }
  },
  {
    id: "archived_epic",
    label: i18n.t("chat:tool_card_assign_job_to_epic_example_archived"),
    input: { job_id: 74, epic_id: 76 },
    resultBody: "Error: epic must not be archived",
    resultError: true
  }
]
