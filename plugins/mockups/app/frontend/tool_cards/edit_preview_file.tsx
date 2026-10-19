import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { parsePreviewFileOp, PreviewErrorCard, PreviewFileOpCard, previewError } from "../previewPanelToolCard"

// Plugin-owned tool card for edit_preview_file (the pending-action tool-card work).
function collapsedSummary(context: ToolCardContext) {
  const error = previewError(context)
  if (error) return `Edit failed: ${error}`
  const op = parsePreviewFileOp(context.parsedResult, context.input)
  return op ? `Edited ${op.path} (panel #${op.panelId})` : null
}

function renderExpanded(context: ToolCardContext) {
  if (context.resultError) return <PreviewErrorCard context={context} title="Edit preview file" />
  const op = parsePreviewFileOp(context.parsedResult, context.input)
  return op ? <PreviewFileOpCard action="Edited file" op={op} /> : null
}

const editPreviewFileToolCard: ToolCardRenderer = {
  toolName: "edit_preview_file",
  collapsedSummary,
  renderExpanded
}

export default editPreviewFileToolCard
