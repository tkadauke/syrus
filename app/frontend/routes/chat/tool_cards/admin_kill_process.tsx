import type { ToolCardExample } from "@app/pluginToolCards"
import { pendingActionToolCard } from "../pendingActionToolCard"

// Pending-action tool card (the pending-action tool-card work). All of the parsing and
// presentation lives in ../pendingActionToolCard so the whole family stays
// consistent; this file only binds it to one MCP tool name.
const adminKillProcessToolCard = pendingActionToolCard("admin_kill_process", {
  inputFields: [
    { key: "process_id", label: "Process", format: "entity", hrefPrefix: "/admin/processes" },
    { key: "process_ids", label: "Processes", format: "entity_list", hrefPrefix: "/admin/processes" }
  ]
})

export const examples: ToolCardExample[] = [
  {
    id: "bulk_process_targets",
    label: "Bulk process targets",
    description: "Shows the concrete linked process targets for a grouped pending action.",
    input: { process_ids: [41, 42, 43] },
    parsedResult: {
      pending_action_group_id: 88,
      pending_action_id: 501,
      pending_confirmation_id: 501,
      state: "pending",
      member_count: 3,
      message: "Kill processes #41, #42, and #43?"
    }
  }
]

export default adminKillProcessToolCard
