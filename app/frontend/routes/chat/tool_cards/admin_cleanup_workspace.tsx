import { pendingActionToolCard } from "../pendingActionToolCard"

const adminCleanupWorkspaceToolCard = pendingActionToolCard("admin_cleanup_workspace", {
  inputFields: [
    { key: "workflow_id", format: "entity", entityKind: "workflow" },
    { key: "reason", format: "markdown" }
  ]
})

export default adminCleanupWorkspaceToolCard
