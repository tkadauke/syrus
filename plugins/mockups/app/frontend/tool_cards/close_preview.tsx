import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { parsePreviewPanel, PreviewPanelCard, previewPanelSummary } from "../previewPanelToolCard"

// Plugin-owned tool card for close_preview (EPIC-292 / JOB-4223). Shares the
// same panel_payload shape and card as show_preview -- this file only binds
// it to the close_preview tool name.
function collapsedSummary(context: ToolCardContext) {
  const panel = parsePreviewPanel(context.parsedResult)
  return panel ? previewPanelSummary(panel) : null
}

function renderExpanded(context: ToolCardContext) {
  const panel = parsePreviewPanel(context.parsedResult)
  return panel ? <PreviewPanelCard panel={panel} /> : null
}

const closePreviewToolCard: ToolCardRenderer = {
  toolName: "close_preview",
  collapsedSummary,
  renderExpanded
}

export default closePreviewToolCard
