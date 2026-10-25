import type { ToolCardExample } from "@app/pluginToolCards"
import i18n from "../../../i18n"
import { maintenanceToolCard } from "../jobEpicMaintenanceToolCard"

export default maintenanceToolCard("remove_job_dependency")

export const examples: ToolCardExample[] = [
  {
    id: "job_dependency_removed",
    label: i18n.t("chat:tool_card_examples.job_dependency_removed"),
    input: { job_id: 50, depends_on_job_id: 49 },
    parsedResult: { job_id: 50, depends_on_job_ids: [48], depends_on_epic_ids: [12] }
  },
  {
    id: "epic_dependency_removed_no_dependencies",
    label: i18n.t("chat:tool_card_examples.epic_dependency_removed_none_remaining"),
    input: { job_id: 50, depends_on_epic_id: 12 },
    parsedResult: { job_id: 50, depends_on_job_ids: [], depends_on_epic_ids: [] }
  },
  {
    id: "validation_error",
    label: i18n.t("chat:tool_card_examples.validation_error"),
    input: { job_id: 50, depends_on_job_id: 49 },
    resultBody: "Error: Job dependency does not exist",
    resultError: true
  }
]
