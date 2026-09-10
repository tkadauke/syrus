import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { InsightDetailBody, parseInsightDetail } from "../agentInsightToolCard"

function collapsedSummary(context: ToolCardContext) {
  const insight = parseInsightDetail(context)
  if (!insight) return null

  return `${insight.title} (${insight.state ?? "unknown"})`
}

function renderExpanded(context: ToolCardContext) {
  const insight = parseInsightDetail(context)
  if (!insight) return null

  return <InsightDetailBody insight={insight} />
}

const readInsightToolCard: ToolCardRenderer = {
  toolName: "read_insight",
  collapsedSummary,
  renderExpanded
}

export default readInsightToolCard
