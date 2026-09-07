import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { parsePendingActionResult, pendingActionCollapsedSummary, PendingActionResultCard } from "../pendingActionToolCard"

// Pending-action tool card (EPIC-292 / JOB-4222). All of the parsing and
// presentation lives in ../pendingActionToolCard so the whole family stays
// consistent; this file only binds it to one MCP tool name.
function collapsedSummary(context: ToolCardContext) {
  const result = parsePendingActionResult(context.parsedResult)
  return result ? pendingActionCollapsedSummary(result) : null
}

function renderExpanded(context: ToolCardContext) {
  const result = parsePendingActionResult(context.parsedResult)
  return result ? <PendingActionResultCard result={result} /> : null
}

const wakeLandingQueueToolCard: ToolCardRenderer = {
  toolName: "wake_landing_queue",
  collapsedSummary,
  renderExpanded
}

export default wakeLandingQueueToolCard
