import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { LocalModeJobOutcomeCard, localModeJobOutcomeSummary, parseLocalModeJobOutcome } from "../localModeJobOutcomeCard"

// Local Mode tool card for open_in_local_mode (the tool-card work). All
// parsing/presentation lives in ../localModeJobOutcomeCard so the family
// (open_in_local_mode, cancel_local_mode, create_coding_job) stays
// consistent; this file only binds it to one MCP tool name.
function collapsedSummary(context: ToolCardContext) {
  const result = parseLocalModeJobOutcome(context.parsedResult)
  return result ? localModeJobOutcomeSummary(result) : null
}

function renderExpanded(context: ToolCardContext) {
  const result = parseLocalModeJobOutcome(context.parsedResult)
  return result ? <LocalModeJobOutcomeCard result={result} /> : null
}

const openInLocalModeToolCard: ToolCardRenderer = {
  toolName: "open_in_local_mode",
  collapsedSummary,
  renderExpanded
}

export default openInLocalModeToolCard
