import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { LocalModeJobOutcomeCard, localModeJobOutcomeSummary, parseLocalModeJobOutcome } from "../localModeJobOutcomeCard"

// Local Mode tool card for cancel_local_mode (the tool-card work). See
// open_in_local_mode.tsx for the shared family this belongs to.
function collapsedSummary(context: ToolCardContext) {
  const result = parseLocalModeJobOutcome(context.parsedResult)
  return result ? localModeJobOutcomeSummary(result) : null
}

function renderExpanded(context: ToolCardContext) {
  const result = parseLocalModeJobOutcome(context.parsedResult)
  return result ? <LocalModeJobOutcomeCard result={result} /> : null
}

const cancelLocalModeToolCard: ToolCardRenderer = {
  toolName: "cancel_local_mode",
  collapsedSummary,
  renderExpanded
}

export default cancelLocalModeToolCard
