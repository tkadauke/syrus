import { pendingActionToolCard } from "../pendingActionToolCard"

const adminRetryStepToolCard = pendingActionToolCard("admin_retry_step", {
  inputFields: [
    { key: "workflow_id", format: "entity", entityKind: "workflow" },
    { key: "workflow_ids", label: "Workflows", format: "entity_list", entityKind: "workflow" },
    { key: "step_slug", label: "Step", format: "badge" },
    { key: "reason", format: "markdown" }
  ]
})

export default adminRetryStepToolCard
