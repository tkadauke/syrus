import type { ToolCardExample } from "@app/pluginToolCards"
import i18n from "@app/i18n"
import { maintenanceToolCard } from "../jobEpicMaintenanceToolCard"

export default maintenanceToolCard("start_epic")

export const examples: ToolCardExample[] = [
  {
    id: "started",
    label: i18n.t("chat:tool_card_examples.epic_started"),
    input: { epic_id: 60 },
    parsedResult: { epic_id: 60, previous_state: "ready", new_state: "in_progress" }
  },
  {
    id: "not_ready",
    label: i18n.t("chat:tool_card_examples.epic_not_ready"),
    input: { epic_id: 61 },
    resultBody: "epic must be ready to start; current state is backlog",
    resultError: true
  },
  {
    id: "product_owner_forbidden",
    label: i18n.t("chat:tool_card_examples.product_owner_cannot_start_epic"),
    input: { epic_id: 62 },
    resultBody: "Product owners cannot advance Epics beyond backlog.",
    resultError: true
  }
]
