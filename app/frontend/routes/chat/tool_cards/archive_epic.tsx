import type { ToolCardExample } from "@app/pluginToolCards"
import { maintenanceToolCard } from "../jobEpicMaintenanceToolCard"

export default maintenanceToolCard("archive_epic")

export const examples: ToolCardExample[] = [
  {
    id: "pending_confirmation",
    label: "Pending destructive confirmation",
    input: { epic_id: 62 },
    parsedResult: {
      pending_action_id: 17,
      pending_confirmation_id: 17,
      state: "pending",
      message: "Archive EPIC-62? Open child Jobs will be cancelled and closed when confirmed."
    }
  },
  {
    id: "validation_error",
    label: "Already archived error",
    input: { epic_id: 62 },
    resultBody: "Error: epic is already archived",
    resultError: true
  }
]
