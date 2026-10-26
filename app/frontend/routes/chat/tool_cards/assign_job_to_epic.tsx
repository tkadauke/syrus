import type { ToolCardExample } from "@app/pluginToolCards"
import i18n from "@app/i18n"
import { maintenanceToolCard } from "../jobEpicMaintenanceToolCard"

export default maintenanceToolCard("assign_job_to_epic")

export const examples: ToolCardExample[] = [
  {
    id: "assigned",
    label: i18n.t("chat:mutation_example_job_assigned_to_epic"),
    input: { job_id: 74, epic_id: 75 },
    parsedResult: { job_id: 74, epic_id: 75, epic_title: "Tool card polish" }
  },
  {
    id: "archived_epic",
    label: i18n.t("chat:mutation_example_archived_epic_error"),
    input: { job_id: 74, epic_id: 76 },
    resultBody: "Error: epic must not be archived",
    resultError: true
  }
]
