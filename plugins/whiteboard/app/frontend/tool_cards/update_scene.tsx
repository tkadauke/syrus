import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { numberValue } from "@app/routes/chat/toolCardUi"
import { SceneCountsCard, sceneCountsSummary, type SceneCounts } from "../whiteboardToolCard"

// Plugin-owned tool card for update_scene (EPIC-292 / JOB-4223). The tool's
// own result is just `{ replaced: true, version }` (see update_scene_tool.rb)
// -- the replacement element/file counts come from the tool call's own input
// instead, which update_scene_tool.rb requires (`elements`) or accepts
// optionally (`files`).
//
// Collapsed-row dispatch never carries `input` at all (see
// app/frontend/routes/chat/toolRendering.ts's toolResultPresentation and the
// ToolCardContext.input doc comment in @app/pluginToolCards) -- only the
// expanded view gets it. Without a real input object we have no counts to
// report, so this must fall back to null (the generic renderer) rather than
// silently claiming "0 elements", which would misrepresent every real
// replacement in the collapsed summary.
function sceneCounts(context: ToolCardContext): SceneCounts | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed) || parsed.replaced !== true) return null
  if (!isPlainObject(context.input) || !Array.isArray(context.input.elements)) return null

  const files = isPlainObject(context.input.files) ? context.input.files : {}

  return { elementCount: context.input.elements.length, fileCount: Object.keys(files).length, version: numberValue(parsed.version) }
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
