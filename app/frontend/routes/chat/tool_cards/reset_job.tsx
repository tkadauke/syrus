import type { ToolCardExample } from "@app/pluginToolCards"
import { maintenanceToolCard } from "../jobEpicMaintenanceToolCard"

export default maintenanceToolCard("reset_job")
export const examples: ToolCardExample[] = [{
  id: "pending", label: "Reset pending confirmation",
  input: { job_id: 50, reason: "Discard the stale implementation." },
  parsedResult: { pending_action_id: 91, state: "pending", message: "Reset JOB-50 from scratch?" }
}]
