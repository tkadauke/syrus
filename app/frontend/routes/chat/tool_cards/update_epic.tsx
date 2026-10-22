import type { ToolCardExample } from "@app/pluginToolCards"
import { maintenanceToolCard } from "../jobEpicMaintenanceToolCard"

export default maintenanceToolCard("update_epic")

const longDescription = `## Updated scope\n\n${"This Epic now covers **responsive** tool cards with linked details. ".repeat(10)}`

export const examples: ToolCardExample[] = [
  {
    id: "title_and_description_updated",
    label: "Title and description updated",
    input: { epic_id: 71, title: "Improve maintenance cards", description: longDescription },
    parsedResult: { epic_id: 71, title: "Improve maintenance cards", description: longDescription, state: "ready" }
  },
  {
    id: "update_failed",
    label: "Epic update failed",
    input: { epic_id: 71, title: "", description: "Keep the **attempted** description visible." },
    resultBody: "Error: title cannot be blank",
    resultError: true
  },
  {
    id: "empty_description_failed",
    label: "Empty description update failed",
    input: { epic_id: 72, description: "" },
    resultBody: "Error: archived Epics cannot be updated",
    resultError: true
  }
]
