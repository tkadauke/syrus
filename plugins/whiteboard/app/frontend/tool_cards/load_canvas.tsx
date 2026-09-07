import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { LoadCanvasCard, parseLoadCanvasResult } from "../whiteboardToolCard"

// Plugin-owned tool card for load_canvas (EPIC-292 / JOB-4223).
function collapsedSummary(context: ToolCardContext) {
  const result = parseLoadCanvasResult(context.parsedResult)
  if (!result) return null

  const snapshot = result.snapshotId ? `#${result.snapshotId}` : "snapshot"
  return `Loaded ${snapshot}${result.mode ? ` (${result.mode})` : ""}`
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
