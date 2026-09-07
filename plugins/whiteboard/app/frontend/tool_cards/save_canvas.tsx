import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { parseSaveCanvasResult, SaveCanvasCard } from "../whiteboardToolCard"

// Plugin-owned tool card for save_canvas (EPIC-292 / JOB-4223).
function collapsedSummary(context: ToolCardContext) {
  const result = parseSaveCanvasResult(context.parsedResult)
  if (!result) return null

  if (!result.saved) return "Canvas not saved (empty)"
  return result.name ? `Saved snapshot "${result.name}"` : "Saved snapshot"
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
