import type { ToolCardExample } from "@app/pluginToolCards"
import { maintenanceToolCard } from "../jobEpicMaintenanceToolCard"

export default maintenanceToolCard("update_job")

const longDescription = `## Updated implementation\n\n${"This Job now renders **complete** update details on mobile and desktop. ".repeat(10)}`

export const examples: ToolCardExample[] = [
  {
    id: "title_and_description_updated",
    label: "Title and description updated",
    input: { job_id: 70, title: "Improve update Job card", description: longDescription },
    parsedResult: { job_id: 70, title: "Improve update Job card", description: longDescription, state: "running" }
  },
  {
    id: "closed_job_update_failed",
    label: "Closed Job update failed",
    input: { job_id: 70, title: "Attempted title", description: "Keep the **attempted** description visible." },
    resultBody: "JOB-70 is closed and cannot be updated.",
    resultError: true
  }
]
