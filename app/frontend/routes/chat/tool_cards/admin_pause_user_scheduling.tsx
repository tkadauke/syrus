import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { parsePendingActionResult, pendingActionCollapsedSummary, pendingActionToolCard } from "../pendingActionToolCard"

// Pending-action tool card (the pending-action tool-card work). All of the parsing and
// presentation lives in ../pendingActionToolCard so the whole family stays
// consistent; this file only binds it to one MCP tool name.
const sharedPendingActionToolCard = pendingActionToolCard("admin_pause_user_scheduling", {
  inputFields: [
    { key: "user_id", label: "User", format: "entity", hrefPrefix: "/admin/users" },
    { key: "user_ids", label: "Users", format: "entity_list", hrefPrefix: "/admin/users" },
    { key: "reason", format: "markdown" }
  ]
})

const adminPauseUserSchedulingToolCard: ToolCardRenderer = {
  ...sharedPendingActionToolCard,
  // The expanded card already presents every target and parameter. Omitting the
  // generic argument digest leaves the collapsed row usable on narrow screens.
  argumentSummary: () => "",
  collapsedSummary(context: ToolCardContext) {
    const result = parsePendingActionResult(context, true)
    if (!result) return null
    if (result.kind === "error") return "Pause scheduling failed"
    if (result.kind === "dry_run_evidence") return pendingActionCollapsedSummary(result)

    const identifier = result.groupId ? `Group #${result.groupId}` : `Pending action #${result.pendingActionId}`
    const count = result.memberCount == null ? "" : ` · ${result.memberCount} ${result.memberCount === 1 ? "action" : "actions"}`
    return `${identifier}${count} · ${result.state}`
  }
}

export default adminPauseUserSchedulingToolCard
