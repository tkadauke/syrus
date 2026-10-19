import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { OutcomeCard, parseOutcome } from "../agentInsightToolCard"

function collapsedSummary(context: ToolCardContext) {
  const outcome = parseOutcome(context)
  if (!outcome) return null

  return outcome.id ? `Updated insight #${outcome.id}` : "Updated insight"
}

function renderExpanded(context: ToolCardContext) {
  return <OutcomeCard context={context} label="Update outcome" />
}

const updateInsightToolCard: ToolCardRenderer = {
  toolName: "update_insight",
  collapsedSummary,
  renderExpanded
}

export default updateInsightToolCard
