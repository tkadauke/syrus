import type { ToolCardExample } from "@app/pluginToolCards"
import i18n from "@app/i18n"
import { maintenanceToolCard } from "../jobEpicMaintenanceToolCard"

export default maintenanceToolCard("set_job_priority")

export const examples: ToolCardExample[] = [
  {
    id: "priority_changed",
    get label() {
      return i18n.t("chat:tool_card_examples.priority_changed")
    },
    input: { job_id: 51, priority: "urgent" },
    parsedResult: { job_id: 51, previous_priority: "medium", new_priority: "urgent" }
  },
  {
    id: "invalid_priority",
    get label() {
      return i18n.t("chat:tool_card_examples.invalid_priority")
    },
    input: { job_id: 51, priority: "immediate" },
    resultBody: "Error: priority must be urgent, high, medium, or low",
    resultError: true
  }
]
