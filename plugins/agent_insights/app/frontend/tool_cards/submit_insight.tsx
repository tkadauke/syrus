import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { OutcomeCard, parseOutcome } from "../agentInsightToolCard"

function collapsedSummary(context: ToolCardContext) {
  const outcome = parseOutcome(context)
  if (!outcome) return null

  return outcome.id ? `Saved insight #${outcome.id}` : "Saved insight"
}

function renderExpanded(context: ToolCardContext) {
  return <OutcomeCard context={context} label="Saved insight" />
}

const submitInsightToolCard: ToolCardRenderer = {
  toolName: "submit_insight",
  collapsedSummary,
  renderExpanded
}

export default submitInsightToolCard
