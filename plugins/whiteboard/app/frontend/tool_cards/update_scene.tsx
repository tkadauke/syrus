import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { numberValue } from "@app/routes/chat/toolCardUi"
import { SceneCountsCard, sceneCountsSummary, type SceneCounts } from "../whiteboardToolCard"

// Plugin-owned tool card for update_scene (EPIC-292 / JOB-4223). The tool's
// own result is just `{ replaced: true, version }` (see update_scene_tool.rb)
// -- the replacement element/file counts come from the tool call's own input
// instead, which update_scene_tool.rb requires (`elements`) or accepts
// optionally (`files`).
function sceneCounts(context: ToolCardContext): SceneCounts | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed) || parsed.replaced !== true) return null

  const input = isPlainObject(context.input) ? context.input : {}
  const elements = Array.isArray(input.elements) ? input.elements : []
  const files = isPlainObject(input.files) ? input.files : {}

  return { elementCount: elements.length, fileCount: Object.keys(files).length, version: numberValue(parsed.version) }
}

function collapsedSummary(context: ToolCardContext) {
  const counts = sceneCounts(context)
  return counts ? `Replaced scene: ${sceneCountsSummary(counts)}` : null
}

function renderExpanded(context: ToolCardContext) {
  const counts = sceneCounts(context)
  return counts ? <SceneCountsCard action="Replaced scene" counts={counts} /> : null
}

const updateSceneToolCard: ToolCardRenderer = {
  toolName: "update_scene",
  collapsedSummary,
  renderExpanded
}

export default updateSceneToolCard
