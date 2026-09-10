import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { ClearCanvasCard, parseClearCanvasResult } from "../whiteboardToolCard"

// Plugin-owned tool card for clear_canvas (the pending-action tool-card work).
function collapsedSummary(context: ToolCardContext) {
  const result = parseClearCanvasResult(context.parsedResult)
  if (!result) return null

  return result.snapshotId ? `Cleared canvas (saved as #${result.snapshotId})` : "Cleared canvas"
}

function renderExpanded(context: ToolCardContext) {
  const result = parseClearCanvasResult(context.parsedResult)
  return result ? <ClearCanvasCard result={result} /> : null
}

const clearCanvasToolCard: ToolCardRenderer = {
  toolName: "clear_canvas",
  collapsedSummary,
  renderExpanded
}

export default clearCanvasToolCard
