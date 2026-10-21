import { pendingActionToolCard } from "../pendingActionToolCard"

// Pending-action tool card (the pending-action tool-card work). All of the parsing and
// presentation lives in ../pendingActionToolCard so the whole family stays
// consistent; this file only binds it to one MCP tool name.
const adminUnpauseUserSchedulingToolCard = pendingActionToolCard("admin_unpause_user_scheduling", {
  inputFields: [
    { key: "user_id", label: "User", format: "entity", hrefPrefix: "/admin/users" },
    { key: "user_ids", label: "Users", format: "entity_list", hrefPrefix: "/admin/users" },
    { key: "reason", format: "markdown" }
  ]
})

export default adminUnpauseUserSchedulingToolCard
