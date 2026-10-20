import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { parsePendingActionResult, pendingActionCollapsedSummary, PendingActionResultCard } from "../pendingActionToolCard"

const card: ToolCardRenderer = {
  toolName: "base_refresh_retry_job",
  collapsedSummary(context: ToolCardContext) {
    const result = parsePendingActionResult(context)
    return result ? pendingActionCollapsedSummary(result) : null
  },
  renderExpanded(context: ToolCardContext) {
    const result = parsePendingActionResult(context)
    return result ? <PendingActionResultCard result={result} /> : null
  }
}

export default card
