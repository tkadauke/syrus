import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { parsePreviewPanel, PreviewPanelCard, previewPanelSummary } from "../previewPanelToolCard"

// Plugin-owned tool card for show_preview (EPIC-292 / JOB-4223). Lives
// entirely inside the mockups plugin -- core discovers it by directory
// convention (see app/frontend/pluginToolCards.tsx) and never imports it by
// name, so it can be added, changed, or removed without touching core.
function collapsedSummary(context: ToolCardContext) {
  const panel = parsePreviewPanel(context.parsedResult)
  return panel ? previewPanelSummary(panel) : null
}

function renderExpanded(context: ToolCardContext) {
  const panel = parsePreviewPanel(context.parsedResult)
  return panel ? <PreviewPanelCard panel={panel} /> : null
}

const showPreviewToolCard: ToolCardRenderer = {
  toolName: "show_preview",
  collapsedSummary,
  renderExpanded
}

export default showPreviewToolCard
