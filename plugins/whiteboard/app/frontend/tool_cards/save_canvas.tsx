import { isPlainObject, type ToolCardContext, type ToolCardExample, type ToolCardRenderer } from "@app/pluginToolCards"
import { displayValue } from "@app/routes/chat/toolCardUi"
import { ToolFailureSummaryCard, toolFailureCollapsedSummary } from "@app/routes/chat/toolFailureSummaryCard"
import { parseSaveCanvasResult, SaveCanvasCard, t } from "../whiteboardToolCard"

// Plugin-owned tool card for save_canvas (the pending-action tool-card work).
function collapsedSummary(context: ToolCardContext) {
  if (context.resultError) return toolFailureCollapsedSummary(context, failureConfig)
  const result = parseSaveCanvasResult(context.parsedResult)
  if (!result) return null

  if (!result.saved) return t("tool_canvas_not_saved_empty")
  return result.name ? t("tool_saved_snapshot_named", { name: result.name }) : t("tool_saved_snapshot")
}

function renderExpanded(context: ToolCardContext) {
  if (context.resultError) return <ToolFailureSummaryCard config={failureConfig} context={context} />
  const result = parseSaveCanvasResult(context.parsedResult)
  const requestedName = isPlainObject(context.input) ? displayValue(context.input.name) : null
  return result ? <SaveCanvasCard requestedName={requestedName} result={result} /> : null
}

const failureConfig = {
  title: t("tool_save_snapshot"),
  attempted: (context: ToolCardContext) => {
    const name = isPlainObject(context.input) ? displayValue(context.input.name) : null
    return name ? t("tool_save_snapshot_named", { name }) : t("tool_save_snapshot")
  },
  retrySafety: "safe" as const,
  recovery: t("tool_save_snapshot_recovery")
}

export const examples: ToolCardExample[] = [
  {
    id: "saved_snapshot",
    label: "Saved snapshot",
    input: { name: "Architecture" },
    parsedResult: { saved: true, snapshot_id: 9, name: "Architecture", element_count: 4, chat_session_id: 12, version: 7 },
    sourceType: "generic"
  },
  {
    id: "empty_canvas",
    label: "Empty canvas",
    input: { name: "Architecture" },
    parsedResult: { saved: false, reason: "canvas is empty", name: "Architecture", chat_session_id: 12, version: 0 },
    sourceType: "generic"
  },
  { id: "error", label: "Error", input: { name: "Architecture" }, resultBody: "Snapshot could not be saved", resultError: true, sourceType: "generic" }
]

const saveCanvasToolCard: ToolCardRenderer = {
  toolName: "save_canvas",
  collapsedSummary,
  renderExpanded
}

export default saveCanvasToolCard
