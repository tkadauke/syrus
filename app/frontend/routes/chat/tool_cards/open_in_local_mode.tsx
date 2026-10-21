import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { LocalModeJobOutcomeToolCard, localModeJobOutcomeModel, localModeJobOutcomeSummary } from "../localModeJobOutcomeCard"

// Local Mode tool card for open_in_local_mode (the tool-card work). All
// parsing/presentation lives in ../localModeJobOutcomeCard so the family
// (open_in_local_mode, cancel_local_mode, create_coding_job) stays
// consistent; this file only binds it to one MCP tool name.
function collapsedSummary(context: ToolCardContext) {
  const model = localModeJobOutcomeModel(context)
  if (model.error) return "Failed to open Local Mode"
  return model.result ? localModeJobOutcomeSummary(model.result) : null
}

function renderExpanded(context: ToolCardContext) {
  const model = localModeJobOutcomeModel(context)
  return model.error || model.result ? <LocalModeJobOutcomeToolCard context={context} /> : null
}

const openInLocalModeToolCard: ToolCardRenderer = {
  toolName: "open_in_local_mode",
  collapsedSummary,
  renderExpanded
}

export default openInLocalModeToolCard
