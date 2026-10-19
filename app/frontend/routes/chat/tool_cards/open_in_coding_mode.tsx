import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { LocalModeJobOutcomeCard, localModeJobOutcomeSummary, parseLocalModeJobOutcome } from "../localModeJobOutcomeCard"

function collapsedSummary(context: ToolCardContext) {
  const result = parseLocalModeJobOutcome(context.parsedResult)
  return result ? localModeJobOutcomeSummary(result) : null
}

function renderExpanded(context: ToolCardContext) {
  const result = parseLocalModeJobOutcome(context.parsedResult)
  return result ? <LocalModeJobOutcomeCard result={result} /> : null
}

const openInCodingModeToolCard: ToolCardRenderer = { toolName: "open_in_coding_mode", collapsedSummary, renderExpanded }

export default openInCodingModeToolCard
