import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { OutcomeBody, parseOutcome } from "../agentInsightToolCard"

function collapsedSummary(context: ToolCardContext) {
  const outcome = parseOutcome(context)
  if (!outcome) return null

  return outcome.id ? `Retired insight #${outcome.id}` : "Retired insight"
}

function renderExpanded(context: ToolCardContext) {
  const outcome = parseOutcome(context)
  if (!outcome) return null

  return <OutcomeBody label="Retirement outcome" outcome={outcome} />
}

const retireInsightToolCard: ToolCardRenderer = {
  toolName: "retire_insight",
  collapsedSummary,
  renderExpanded
}

export default retireInsightToolCard
