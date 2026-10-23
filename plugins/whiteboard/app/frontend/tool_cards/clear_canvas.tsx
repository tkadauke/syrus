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
  return result ? <ClearCanvasCard result={result} /> : null
}

const failureConfig = {
  title: t("tool_clear_canvas"),
  attempted: () => t("tool_clear_canvas"),
  retrySafety: "caution" as const,
  recovery: t("tool_clear_canvas_recovery")
}

export const examples: ToolCardExample[] = [
  {
    id: "cleared_with_snapshot",
    label: "Cleared with auto-save",
    parsedResult: { cleared: true, snapshot_id: 3, element_count: 4, chat_session_id: 12, version: 5 },
    sourceType: "generic"
  },
  {
    id: "already_empty",
    label: "Already empty",
    parsedResult: { cleared: true, snapshot_id: null, element_count: 0, chat_session_id: 12, version: 1 },
    sourceType: "generic"
  },
  { id: "error", label: "Error", resultBody: "Canvas could not be cleared", resultError: true, sourceType: "generic" }
]

const clearCanvasToolCard: ToolCardRenderer = {
  toolName: "clear_canvas",
  collapsedSummary,
  renderExpanded
}

export default clearCanvasToolCard
