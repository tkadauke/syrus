import { pendingActionToolCard } from "../pendingActionToolCard"

// Pending-action tool card (the pending-action tool-card work). All of the parsing and
// presentation lives in ../pendingActionToolCard so the whole family stays
// consistent; this file only binds it to one MCP tool name.
const adminCleanupWorkspaceToolCard = pendingActionToolCard("admin_cleanup_workspace", {
  inputFields: [
    { key: "workflow_id", label: "Workflow", format: "entity", entityKind: "workflow", hrefPrefix: "/admin/workflows" },
    { key: "reason", format: "markdown" }
  ]
})

export default adminCleanupWorkspaceToolCard
