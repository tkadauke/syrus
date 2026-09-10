import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { OutcomeBody, parseOutcome } from "../agentInsightToolCard"

function collapsedSummary(context: ToolCardContext) {
  const outcome = parseOutcome(context)
  if (!outcome) return null

  return outcome.id ? `Saved insight #${outcome.id}` : "Saved insight"
}

function renderExpanded(context: ToolCardContext) {
  const outcome = parseOutcome(context)
  if (!outcome) return null

  return <OutcomeBody label="Saved insight" outcome={outcome} />
}

const submitInsightToolCard: ToolCardRenderer = {
  toolName: "submit_insight",
  collapsedSummary,
  renderExpanded
}

export default submitInsightToolCard
