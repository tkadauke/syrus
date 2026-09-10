import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { insightListSummary, insightRows, InsightListBody } from "../agentInsightToolCard"

function collapsedSummary(context: ToolCardContext) {
  return insightListSummary(context)
}

function renderExpanded(context: ToolCardContext) {
  const rows = insightRows(context)
  if (!rows) return null

  return <InsightListBody rows={rows} />
}

const listInsightsToolCard: ToolCardRenderer = {
  toolName: "list_insights",
  collapsedSummary,
  renderExpanded
}

export default listInsightsToolCard
