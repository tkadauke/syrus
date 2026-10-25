import type { ToolCardExample } from "@app/pluginToolCards"
import i18n from "../../../i18n"
import { maintenanceToolCard } from "../jobEpicMaintenanceToolCard"

export default maintenanceToolCard("move_epic_to_backlog")

export const examples: ToolCardExample[] = [
  {
    id: "moved_to_backlog",
    label: i18n.t("chat:tool_card_examples.epic_moved_to_backlog"),
    input: { epic_id: 61, epic_title: "Improve maintenance cards" },
    parsedResult: { epic_id: 61, previous_state: "ready", new_state: "backlog" }
  },
  {
    id: "not_movable",
    label: i18n.t("chat:tool_card_examples.epic_cannot_move_to_backlog"),
    input: { epic_id: 62, epic_title: "Already completed Epic" },
    resultBody: "Error: Epic cannot be moved to backlog from completed",
    resultError: true
  }
]
