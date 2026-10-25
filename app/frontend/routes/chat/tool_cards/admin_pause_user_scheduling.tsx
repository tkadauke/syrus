import i18n from "../../../i18n"
import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { parsePendingActionResult, pendingActionToolCard } from "../pendingActionToolCard"

// Pending-action tool card (the pending-action tool-card work). All of the parsing and
// presentation lives in ../pendingActionToolCard so the whole family stays
// consistent; this file only binds it to one MCP tool name.
const sharedPendingActionToolCard = pendingActionToolCard("admin_pause_user_scheduling", {
  inputFields: [
    { key: "user_id", label: i18n.t("chat:ops_user_9f8a23"), format: "entity", hrefPrefix: "/admin/users" },
    { key: "user_ids", label: i18n.t("chat:ops_users_57f2b1"), format: "entity_list", hrefPrefix: "/admin/users" },
    { key: "reason", format: "markdown" }
  ]
})

const adminPauseUserSchedulingToolCard: ToolCardRenderer = {
  ...sharedPendingActionToolCard,
  toolName: "admin_pause_user_scheduling",
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
