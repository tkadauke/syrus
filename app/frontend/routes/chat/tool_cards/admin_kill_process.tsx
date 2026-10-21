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

export default adminKillProcessToolCard
