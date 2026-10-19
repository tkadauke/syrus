import i18n from "i18next"
import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { OutcomeCard, parseOutcome } from "../agentInsightToolCard"

function collapsedSummary(context: ToolCardContext) {
  const outcome = parseOutcome(context)
  if (!outcome) return null

  return outcome.id ? i18n.t("agent_insights:tool_retire_summary_with_id", { id: outcome.id }) : i18n.t("agent_insights:tool_retire_summary")
}

function renderExpanded(context: ToolCardContext) {
  return <OutcomeCard context={context} label={i18n.t("agent_insights:tool_retire_label")} />
}

const retireInsightToolCard: ToolCardRenderer = {
  toolName: "retire_insight",
  collapsedSummary,
  renderExpanded
}

export default retireInsightToolCard
