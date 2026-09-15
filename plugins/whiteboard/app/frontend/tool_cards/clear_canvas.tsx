import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { ClearCanvasCard, parseClearCanvasResult, t } from "../whiteboardToolCard"

// Plugin-owned tool card for clear_canvas (the pending-action tool-card work).
function collapsedSummary(context: ToolCardContext) {
  const result = parseClearCanvasResult(context.parsedResult)
  if (!result) return null

  return result.snapshotId ? t("tool_cleared_canvas_saved_as", { id: result.snapshotId }) : t("tool_cleared_canvas")
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
