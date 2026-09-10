import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { parsePreviewFileOp, PreviewFileOpCard } from "../previewPanelToolCard"

// Plugin-owned tool card for edit_preview_file (the pending-action tool-card work).
function collapsedSummary(context: ToolCardContext) {
  const op = parsePreviewFileOp(context.parsedResult)
  return op ? `Edited ${op.path} (panel #${op.panelId})` : null
}

function renderExpanded(context: ToolCardContext) {
  const op = parsePreviewFileOp(context.parsedResult)
  return op ? <PreviewFileOpCard action="Edited file" op={op} /> : null
}

const editPreviewFileToolCard: ToolCardRenderer = {
  toolName: "edit_preview_file",
  collapsedSummary,
  renderExpanded
}

export default editPreviewFileToolCard
