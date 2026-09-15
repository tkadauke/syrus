import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { parseSceneCounts, SceneCountsCard, sceneCountsSummary, t } from "../whiteboardToolCard"

// Plugin-owned tool card for read_scene (the pending-action tool-card work).
function collapsedSummary(context: ToolCardContext) {
  const counts = parseSceneCounts(context.parsedResult)
  return counts ? sceneCountsSummary(counts) : null
}

function renderExpanded(context: ToolCardContext) {
  const counts = parseSceneCounts(context.parsedResult)
  return counts ? <SceneCountsCard action={t("tool_scene")} counts={counts} /> : null
}

const readSceneToolCard: ToolCardRenderer = {
  toolName: "read_scene",
  collapsedSummary,
  renderExpanded
}

export default readSceneToolCard
