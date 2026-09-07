import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { parseSceneCounts, SceneCountsCard, sceneCountsSummary } from "../whiteboardToolCard"

// Plugin-owned tool card for read_scene (EPIC-292 / JOB-4223).
function collapsedSummary(context: ToolCardContext) {
  const counts = parseSceneCounts(context.parsedResult)
  return counts ? sceneCountsSummary(counts) : null
}

function renderExpanded(context: ToolCardContext) {
  const counts = parseSceneCounts(context.parsedResult)
  return counts ? <SceneCountsCard action="Scene" counts={counts} /> : null
}

const readSceneToolCard: ToolCardRenderer = {
  toolName: "read_scene",
  collapsedSummary,
  renderExpanded
}

export default readSceneToolCard
