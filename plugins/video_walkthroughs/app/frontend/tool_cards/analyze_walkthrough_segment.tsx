import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { renderSegment, segmentExamples, segmentSummary } from "../videoWalkthroughAnalysisToolCard"

function collapsedSummary(context: ToolCardContext) {
  return segmentSummary(context)
}

function renderExpanded(context: ToolCardContext) {
  return renderSegment(context)
}

const analyzeWalkthroughSegmentToolCard: ToolCardRenderer = {
  toolName: "analyze_walkthrough_segment",
  collapsedSummary,
  renderExpanded
}

export const examples = segmentExamples

export default analyzeWalkthroughSegmentToolCard
