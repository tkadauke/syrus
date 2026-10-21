import { pendingActionToolCard } from "../pendingActionToolCard"

// Pending-action tool card (the pending-action tool-card work). All of the parsing and
// presentation lives in ../pendingActionToolCard so the whole family stays
// consistent; this file only binds it to one MCP tool name.
const adminRetryStepToolCard = pendingActionToolCard("admin_retry_step", {
  inputFields: [
    { key: "workflow_id", label: "Workflow", format: "entity", entityKind: "workflow", hrefPrefix: "/admin/workflows" },
    { key: "workflow_ids", label: "Workflows", format: "entity_list", entityKind: "workflow", hrefPrefix: "/admin/workflows" },
    { key: "step_slug", label: "Step", format: "badge" },
    { key: "reason", format: "markdown" }
  ]
})

export default adminRetryStepToolCard
