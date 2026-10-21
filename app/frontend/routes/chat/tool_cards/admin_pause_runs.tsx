import type { ToolCardExample } from "@app/pluginToolCards"
import { pendingActionToolCard } from "../pendingActionToolCard"

// Pending-action tool card (the pending-action tool-card work). All of the parsing and
// presentation lives in ../pendingActionToolCard so the whole family stays
// consistent; this file only binds it to one MCP tool name.
const adminPauseRunsToolCard = pendingActionToolCard("admin_pause_runs")

export const examples: ToolCardExample[] = [
  {
    id: "provider_error",
    label: "Tool error",
    description: "Shows a failed pending-action request returned in an MCP text-content envelope.",
    parsedResult: { content: [{ type: "text", text: "Run control is temporarily unavailable. Retry after the active deployment finishes." }] },
    resultError: true
  }
]

export default adminPauseRunsToolCard
