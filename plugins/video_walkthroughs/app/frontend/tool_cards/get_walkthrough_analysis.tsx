import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { fullAnalysisExamples, fullAnalysisSummary, renderFullAnalysis } from "../videoWalkthroughAnalysisToolCard"

function collapsedSummary(context: ToolCardContext) {
  return fullAnalysisSummary(context)
}

function renderExpanded(context: ToolCardContext) {
  return renderFullAnalysis(context)
}

const getWalkthroughAnalysisToolCard: ToolCardRenderer = {
  toolName: "get_walkthrough_analysis",
  collapsedSummary,
  renderExpanded
}

export const examples = fullAnalysisExamples

export default getWalkthroughAnalysisToolCard
