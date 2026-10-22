import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { parsePendingActionResult, pendingActionToolCard } from "../pendingActionToolCard"

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
  // generic argument digest and successful result summary leaves the collapsed
  // row usable on narrow screens, where the shared header has no room for a
  // fourth inline column. The title and outcome remain visible in that row.
  argumentSummary: () => "",
  collapsedSummary(context: ToolCardContext) {
    const result = parsePendingActionResult(context, true)
    return result?.kind === "error" ? "Error" : null
  }
}

export default adminPauseUserSchedulingToolCard
