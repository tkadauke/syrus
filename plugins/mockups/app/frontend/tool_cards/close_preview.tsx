import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { parsePreviewPanel, PreviewErrorCard, PreviewPanelCard, previewError, previewPanelSummary, previewPanelText } from "../previewPanelToolCard"

// Plugin-owned tool card for close_preview (the pending-action tool-card work). Shares the
// same panel_payload shape and card as show_preview -- this file only binds
// it to the close_preview tool name.
function collapsedSummary(context: ToolCardContext) {
  const error = previewError(context)
  if (error) return previewPanelText("tool_failed_summary", { operation: previewPanelText("tool_close_preview"), error })
  const panel = parsePreviewPanel(context.parsedResult, context.input)
  return panel ? previewPanelSummary(panel) : null
}

function renderExpanded(context: ToolCardContext) {
  if (context.resultError) return <PreviewErrorCard context={context} title={previewPanelText("tool_close_preview")} />
  const panel = parsePreviewPanel(context.parsedResult, context.input)
  return panel ? <PreviewPanelCard panel={panel} /> : null
}

const closePreviewToolCard: ToolCardRenderer = {
  toolName: "close_preview",
  collapsedSummary,
  renderExpanded
}

export default closePreviewToolCard
