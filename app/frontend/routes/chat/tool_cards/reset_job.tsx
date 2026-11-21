import type { ToolCardExample } from "@app/pluginToolCards"
import { maintenanceToolCard } from "../jobEpicMaintenanceToolCard"

export default maintenanceToolCard("reset_job")
export const examples: ToolCardExample[] = [
  {
    id: "pending",
    label: "Reset pending confirmation",
    input: { job_id: 50, reason: "Discard the stale implementation." },
    parsedResult: {
      pending_action_id: 91,
      state: "pending",
      message: "Reset JOB-50 from scratch?",
      destroys: {
        open_pr_number: 812,
        branch: "syrus/stale-implementation",
        checkpoints: 3,
        active_workflows: [65840, 65841]
      }
    }
  }
]
