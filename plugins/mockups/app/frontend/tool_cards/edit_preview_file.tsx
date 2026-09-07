import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { parsePreviewFileOp, PreviewFileOpCard } from "../previewPanelToolCard"

// Plugin-owned tool card for edit_preview_file (EPIC-292 / JOB-4223).
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
