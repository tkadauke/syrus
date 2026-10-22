import type { ToolCardExample } from "@app/pluginToolCards"
import { maintenanceToolCard } from "../jobEpicMaintenanceToolCard"

export default maintenanceToolCard("start_epic")

export const examples: ToolCardExample[] = [
  {
    id: "started",
    label: "Epic started",
    input: { epic_id: 60 },
    parsedResult: { epic_id: 60, previous_state: "ready", new_state: "in_progress" }
  },
  {
    id: "not_ready",
    label: "Epic is not ready",
    input: { epic_id: 61 },
    resultBody: "epic must be ready to start; current state is backlog",
    resultError: true
  },
  {
    id: "product_owner_forbidden",
    label: "Product owner cannot start Epic",
    input: { epic_id: 62 },
    resultBody: "Product owners cannot advance Epics beyond backlog.",
    resultError: true
  }
]
