import type { ToolCardExample } from "@app/pluginToolCards"
import { maintenanceToolCard } from "../jobEpicMaintenanceToolCard"
import i18n from "@app/i18n"

export default maintenanceToolCard("update_job")

const longDescription = `## Updated implementation\n\n${"This Job now renders **complete** update details on mobile and desktop. ".repeat(10)}`
const updatedTitle = "Improve update Job card"
const attemptedTitle = "Attempted title"
const attemptedDescription = "Keep the **attempted** description visible."

export const examples: ToolCardExample[] = [
  {
    id: "title_and_description_updated",
    get label() {
      return i18n.t("chat:mutation_example_title_and_description_updated")
    },
    input: { job_id: 70, title: updatedTitle, description: longDescription },
    parsedResult: { job_id: 70, title: updatedTitle, description: longDescription, state: "running" }
  },
  {
    id: "closed_job_update_failed",
    get label() {
      return i18n.t("chat:mutation_example_closed_job_update_failed")
    },
    input: { job_id: 70, title: attemptedTitle, description: attemptedDescription },
    resultBody: "JOB-70 is closed and cannot be updated.",
    resultError: true
  }
]
