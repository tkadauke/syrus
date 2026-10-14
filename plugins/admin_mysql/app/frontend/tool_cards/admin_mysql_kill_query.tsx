import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { parsePendingActionResult, pendingActionCollapsedSummary, PendingActionResultCard } from "@app/routes/chat/pendingActionToolCard"

function collapsedSummary(context: ToolCardContext) {
  const result = parsePendingActionResult(context)
  return result ? pendingActionCollapsedSummary(result) : null
}

function renderExpanded(context: ToolCardContext) {
  const result = parsePendingActionResult(context)
  return result ? <PendingActionResultCard result={result} /> : null
}

const adminMysqlKillQueryToolCard: ToolCardRenderer = {
  toolName: "admin_mysql_kill_query",
  collapsedSummary,
  renderExpanded
}

export default adminMysqlKillQueryToolCard
