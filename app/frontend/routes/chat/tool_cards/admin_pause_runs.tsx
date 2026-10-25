import i18n from "../../../i18n"
import type { ToolCardExample } from "@app/pluginToolCards"
import { pendingActionToolCard } from "../pendingActionToolCard"

// Pending-action tool card (the pending-action tool-card work). All of the parsing and
// presentation lives in ../pendingActionToolCard so the whole family stays
// consistent; this file only binds it to one MCP tool name.
const adminPauseRunsToolCard = pendingActionToolCard("admin_pause_runs")

export const examples: ToolCardExample[] = [
  {
    id: "provider_error",
    label: i18n.t("chat:ops_tool_error_7e2d1e"),
    description: i18n.t("chat:ops_shows_a_failed_pending_action_request_returned_in_an_mcp_a3e703"),
    parsedResult: { content: [{ type: "text", text: "Run control is temporarily unavailable. Retry after the active deployment finishes." }] },
    resultError: true
  }
]

export default adminPauseRunsToolCard
