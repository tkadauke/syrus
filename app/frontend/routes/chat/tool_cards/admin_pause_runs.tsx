import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import { parsePendingActionResult, pendingActionCollapsedSummary, PendingActionResultCard } from "../pendingActionToolCard"

// Pending-action tool card (the pending-action tool-card work). All of the parsing and
// presentation lives in ../pendingActionToolCard so the whole family stays
// consistent; this file only binds it to one MCP tool name.
function collapsedSummary(context: ToolCardContext) {
  const result = parsePendingActionResult(context)
  return result ? pendingActionCollapsedSummary(result) : null
}

function renderExpanded(context: ToolCardContext) {
  const result = parsePendingActionResult(context)
  return result ? <PendingActionResultCard result={result} /> : null
}

const adminPauseRunsToolCard: ToolCardRenderer = {
  toolName: "admin_pause_runs",
  collapsedSummary,
  renderExpanded
}

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
