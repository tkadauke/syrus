import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { LoadCanvasCard, parseLoadCanvasResult, t } from "../whiteboardToolCard"

// Plugin-owned tool card for load_canvas (the pending-action tool-card work).
function collapsedSummary(context: ToolCardContext) {
  const result = parseLoadCanvasResult(context.parsedResult)
  if (!result) return null

  const snapshot = result.snapshotId ? `#${result.snapshotId}` : t("tool_snapshot")
  return t("tool_loaded_canvas_summary", { snapshot, mode: result.mode ? ` (${result.mode})` : "" })
}

function renderExpanded(context: ToolCardContext) {
  const result = parseLoadCanvasResult(context.parsedResult)
  return result ? <LoadCanvasCard result={result} /> : null
}

const loadCanvasToolCard: ToolCardRenderer = {
  toolName: "load_canvas",
  collapsedSummary,
  renderExpanded
}

export default loadCanvasToolCard
