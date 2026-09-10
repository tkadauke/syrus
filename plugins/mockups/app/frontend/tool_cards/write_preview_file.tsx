import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { parsePreviewFileOp, PreviewFileOpCard } from "../previewPanelToolCard"

// Plugin-owned tool card for write_preview_file (the pending-action tool-card work).
function collapsedSummary(context: ToolCardContext) {
  const op = parsePreviewFileOp(context.parsedResult)
  return op ? `Wrote ${op.path} (panel #${op.panelId})` : null
}

function renderExpanded(context: ToolCardContext) {
  const op = parsePreviewFileOp(context.parsedResult)
  return op ? <PreviewFileOpCard action="Wrote file" op={op} /> : null
}

const writePreviewFileToolCard: ToolCardRenderer = {
  toolName: "write_preview_file",
  collapsedSummary,
  renderExpanded
}

export default writePreviewFileToolCard
