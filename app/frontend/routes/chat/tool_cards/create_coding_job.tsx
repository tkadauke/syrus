import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { LocalModeJobOutcomeCard, localModeJobOutcomeSummary, parseLocalModeJobOutcome } from "../localModeJobOutcomeCard"

// Local Mode tool card for create_coding_job (EPIC-293 / JOB-4225). See
// open_in_local_mode.tsx for the shared family this belongs to.
function collapsedSummary(context: ToolCardContext) {
  const result = parseLocalModeJobOutcome(context.parsedResult)
  return result ? localModeJobOutcomeSummary(result) : null
}

function renderExpanded(context: ToolCardContext) {
  const result = parseLocalModeJobOutcome(context.parsedResult)
  return result ? <LocalModeJobOutcomeCard result={result} /> : null
}

const createCodingJobToolCard: ToolCardRenderer = {
  toolName: "create_coding_job",
  collapsedSummary,
  renderExpanded
}

export default createCodingJobToolCard
