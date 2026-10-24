import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import { ToolFailureSummaryCard, toolFailureCollapsedSummary } from "@app/routes/chat/toolFailureSummaryCard"
import { ClearCanvasCard, parseClearCanvasResult, t } from "../whiteboardToolCard"

// Plugin-owned tool card for clear_canvas (the pending-action tool-card work).
function collapsedSummary(context: ToolCardContext) {
  if (context.resultError) return toolFailureCollapsedSummary(context, failureConfig)
  const result = parseClearCanvasResult(context.parsedResult)
  if (!result) return null

  return result.snapshotId ? t("tool_cleared_canvas_saved_as", { id: result.snapshotId }) : t("tool_cleared_canvas")
}

function renderExpanded(context: ToolCardContext) {
  if (context.resultError) return <ToolFailureSummaryCard config={failureConfig} context={context} />
  const result = parseClearCanvasResult(context.parsedResult)
  const chatId = context.presentation?.chatId ?? context.chatSessionId
  return result ? <ClearCanvasCard chatId={chatId == null ? null : String(chatId)} result={result} /> : null
}

const failureConfig = {
  title: t("tool_clear_canvas"),
  attempted: () => t("tool_clear_canvas"),
  retrySafety: "safe" as const,
  recovery: t("tool_clear_canvas_recovery")
}

export const examples: ToolCardExample[] = [
  {
    id: "cleared_canvas",
    label: "Cleared canvas",
    parsedResult: {
      cleared: true,
      snapshot_id: 3,
      element_count: 5,
      chat_session_id: 12,
      version: 4,
      preview_scene: {
        elements: [
          { id: "title", type: "text", x: 120, y: 70, width: 260, height: 35, text: "Architecture plan", fontSize: 28 },
          { id: "client", type: "rectangle", x: 80, y: 150, width: 180, height: 100, strokeColor: "#b6492e", backgroundColor: "#fdf2ee" },
          { id: "server", type: "rectangle", x: 360, y: 150, width: 180, height: 100, strokeColor: "#334155", backgroundColor: "#f1f5f9" },
          { id: "flow", type: "arrow", x: 260, y: 200, width: 100, height: 0, strokeColor: "#64748b", endArrowhead: "arrow" },
          { id: "note", type: "text", x: 177, y: 300, width: 270, height: 25, text: "Auto-saved before clearing", fontSize: 20 }
        ],
        appState: { viewBackgroundColor: "#ffffff" },
        files: {}
      }
    },
    sourceType: "generic"
  },
  { id: "already_empty", label: "Already empty", parsedResult: { cleared: true, snapshot_id: null, version: 1 }, sourceType: "generic" },
  { id: "error", label: "Error", resultBody: "Canvas could not be cleared", resultError: true, sourceType: "generic" }
]

const clearCanvasToolCard: ToolCardRenderer = {
  toolName: "clear_canvas",
  collapsedSummary,
  renderExpanded
}

export default clearCanvasToolCard
