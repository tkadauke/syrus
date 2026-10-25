import type { ToolCardExample } from "@app/pluginToolCards"
import i18n from "@app/i18n"
import { maintenanceToolCard } from "../jobEpicMaintenanceToolCard"

export default maintenanceToolCard("update_job")

const longDescription = `## Updated implementation\n\n${"This Job now renders **complete** update details on mobile and desktop. ".repeat(10)}`

export const examples: ToolCardExample[] = [
  {
    id: "title_and_description_updated",
    label: i18n.t("chat:tool_card_update_example_title_description"),
    input: { job_id: 70, title: i18n.t("chat:tool_card_update_job_example_title"), description: longDescription },
    parsedResult: { job_id: 70, title: i18n.t("chat:tool_card_update_job_example_title"), description: longDescription, state: "running" }
  },
  {
    id: "closed_job_update_failed",
    label: i18n.t("chat:tool_card_update_job_example_closed"),
    input: {
      job_id: 70,
      title: i18n.t("chat:tool_card_update_example_attempted_title"),
      description: i18n.t("chat:tool_card_update_example_attempted_description")
    },
    resultBody: "JOB-70 is closed and cannot be updated.",
    resultError: true
  }
]
