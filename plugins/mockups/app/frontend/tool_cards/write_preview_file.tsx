import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { parsePreviewFileOp, PreviewErrorCard, PreviewFileOpCard, previewError } from "../previewPanelToolCard"

// Plugin-owned tool card for write_preview_file (the pending-action tool-card work).
function collapsedSummary(context: ToolCardContext) {
  const error = previewError(context)
  if (error) return `Write failed: ${error}`
  const op = parsePreviewFileOp(context.parsedResult, context.input)
  return op ? `Wrote ${op.path} (panel #${op.panelId})` : null
}

function renderExpanded(context: ToolCardContext) {
  if (context.resultError) return <PreviewErrorCard context={context} title="Write preview file" />
  const op = parsePreviewFileOp(context.parsedResult, context.input)
  return op ? <PreviewFileOpCard action="Wrote file" op={op} /> : null
}

const writePreviewFileToolCard: ToolCardRenderer = {
  toolName: "write_preview_file",
  collapsedSummary,
  renderExpanded
}

export default writePreviewFileToolCard
