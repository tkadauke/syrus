import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import { ToolFailureSummaryCard, toolFailureCollapsedSummary } from "@app/routes/chat/toolFailureSummaryCard"
import { parseSceneCounts, SceneCountsCard, sceneCountsSummary, t } from "../whiteboardToolCard"

// Plugin-owned tool card for read_scene (the pending-action tool-card work).
function collapsedSummary(context: ToolCardContext) {
  if (context.resultError) return toolFailureCollapsedSummary(context, failureConfig)
  const counts = parseSceneCounts(context.parsedResult)
  return counts ? sceneCountsSummary(counts) : null
}

function renderExpanded(context: ToolCardContext) {
  if (context.resultError) return <ToolFailureSummaryCard config={failureConfig} context={context} />
  const counts = parseSceneCounts(context.parsedResult)
  return counts ? <SceneCountsCard action={t("tool_scene")} counts={counts} /> : null
}

const failureConfig = {
  title: t("tool_read_scene"),
  attempted: () => t("tool_read_scene"),
  retrySafety: "safe" as const,
  recovery: t("tool_read_scene_recovery")
}

export const examples: ToolCardExample[] = [
  {
    id: "scene",
    label: "Scene",
    input: {},
    parsedResult: {
      version: 8,
      elements: [
        { id: "heading", type: "text", x: 40, y: 30, text: "Release plan", fontSize: 28 },
        { id: "box", type: "rectangle", x: 30, y: 80, width: 220, height: 100, backgroundColor: "#dbeafe" },
        { id: "arrow", type: "arrow", x: 250, y: 130, width: 120, height: 0 }
      ],
      appState: { viewBackgroundColor: "#ffffff" },
      files: {}
    },
    sourceType: "generic"
  },
  { id: "empty", label: "Empty scene", input: {}, parsedResult: { version: 0, elements: [], appState: {}, files: {} }, sourceType: "generic" },
  { id: "error", label: "Error", input: {}, resultBody: "Scene could not be read", resultError: true, sourceType: "generic" }
]

const readSceneToolCard: ToolCardRenderer = {
  toolName: "read_scene",
  collapsedSummary,
  renderExpanded
}

export default readSceneToolCard
