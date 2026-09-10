import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { parsePinnedContextResult, PinnedContextCard, pinnedContextSummary } from "../pinnedContextToolCard"

function collapsedSummary(context: ToolCardContext) {
  return pinnedContextSummary(context)
}

function renderExpanded(context: ToolCardContext) {
  const result = parsePinnedContextResult(context)
  return result ? <PinnedContextCard error={context.resultError} result={result} /> : null
}

const updatePinnedContextToolCard: ToolCardRenderer = {
  toolName: "update_pinned_context",
  collapsedSummary,
  renderExpanded
}

export default updatePinnedContextToolCard
