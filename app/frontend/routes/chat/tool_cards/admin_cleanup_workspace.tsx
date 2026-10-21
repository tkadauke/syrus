import type { ToolCardExample } from "@app/pluginToolCards"
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

const result = {
  pending_action_id: 501,
  pending_confirmation_id: 501,
  message: "Clean the workspace for workflow #61288?",
  reason: "The workspace is no longer needed after the completed review."
}

export const examples: ToolCardExample[] = [
  {
    id: "pending_cleanup",
    label: "Pending cleanup",
    input: { workflow_id: 61288, reason: "Remove the **completed** workflow workspace." },
    parsedResult: { ...result, state: "pending" }
  },
  {
    id: "confirmed_cleanup",
    label: "Confirmed cleanup",
    input: { workflow_id: 61288, reason: "Remove the **completed** workflow workspace." },
    parsedResult: { ...result, state: "confirmed" }
  },
  {
    id: "rejected_cleanup",
    label: "Rejected cleanup",
    input: { workflow_id: 61288, reason: "Remove the **completed** workflow workspace." },
    parsedResult: { ...result, state: "rejected", reason: "Keep it for another review pass." }
  },
  {
    id: "cleanup_error",
    label: "Cleanup error",
    input: { workflow_id: 61288, reason: "Remove the **completed** workflow workspace." },
    parsedResult: { content: [{ type: "text", text: "Workspace cleanup is temporarily unavailable." }] },
    resultError: true
  }
]

export default adminCleanupWorkspaceToolCard
