import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { parseSaveCanvasResult, SaveCanvasCard, t } from "../whiteboardToolCard"

// Plugin-owned tool card for save_canvas (the pending-action tool-card work).
function collapsedSummary(context: ToolCardContext) {
  const result = parseSaveCanvasResult(context.parsedResult)
  if (!result) return null

  if (!result.saved) return t("tool_canvas_not_saved_empty")
  return result.name ? t("tool_saved_snapshot_named", { name: result.name }) : t("tool_saved_snapshot")
}

function renderExpanded(context: ToolCardContext) {
  const result = parseSaveCanvasResult(context.parsedResult)
  return result ? <SaveCanvasCard result={result} /> : null
}

const saveCanvasToolCard: ToolCardRenderer = {
  toolName: "save_canvas",
  collapsedSummary,
  renderExpanded
}

export default saveCanvasToolCard
