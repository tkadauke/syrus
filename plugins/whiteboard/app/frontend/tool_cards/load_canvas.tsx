import { isPlainObject, type ToolCardContext, type ToolCardExample, type ToolCardRenderer } from "@app/pluginToolCards"
import { displayValue } from "@app/routes/chat/toolCardUi"
import { ToolFailureSummaryCard, toolFailureCollapsedSummary, toolFailureDetected, type ToolFailureConfig } from "@app/routes/chat/toolFailureSummaryCard"
import { LoadCanvasCard, parseLoadCanvasResult, t } from "../whiteboardToolCard"

// Plugin-owned tool card for load_canvas (the pending-action tool-card work).
function collapsedSummary(context: ToolCardContext) {
  if (toolFailureDetected(context)) return toolFailureCollapsedSummary(context, failureConfig)
  const result = parseLoadCanvasResult(context.parsedResult)
  if (!result) return null

  const snapshotId = result.snapshotId ?? inputValue(context, "snapshot_id")
  const mode = result.mode ?? inputValue(context, "mode") ?? "merge"
  const snapshot = snapshotId ? `#${snapshotId}` : t("tool_snapshot")
  return t("tool_loaded_canvas_summary", { snapshot, mode: ` (${t(`tool_mode_${mode}`)})` })
}

function renderExpanded(context: ToolCardContext) {
  if (toolFailureDetected(context)) return <ToolFailureSummaryCard config={failureConfig} context={context} />
  const result = parseLoadCanvasResult(context.parsedResult)
  if (!result) return null

  return (
    <LoadCanvasCard
      result={{
        ...result,
        snapshotId: result.snapshotId ?? inputValue(context, "snapshot_id"),
        mode: result.mode ?? inputValue(context, "mode") ?? "merge"
      }}
    />
  )
}

function inputValue(context: ToolCardContext, key: string) {
  return isPlainObject(context.input) ? displayValue(context.input[key]) : null
}

const failureConfig: ToolFailureConfig = {
  title: t("tool_load_snapshot"),
  attempted: (context) => {
    const snapshotId = inputValue(context, "snapshot_id")
    const mode = inputValue(context, "mode") ?? "merge"
    return t("tool_load_snapshot_attempt", { snapshot: snapshotId ? `#${snapshotId}` : t("tool_snapshot"), mode: t(`tool_mode_${mode}`) })
  },
  retrySafety: "caution",
  recovery: t("tool_load_snapshot_recovery")
}

export const examples: ToolCardExample[] = [
  {
    id: "merge",
    label: "Merge snapshot",
    input: { snapshot_id: 8, mode: "merge" },
    parsedResult: { loaded: true, elements_added: 6, auto_saved_snapshot_id: null, snapshot_id: 8, mode: "merge", chat_session_id: 12, version: 3 },
    sourceType: "generic"
  },
  {
    id: "replace_with_backup",
    label: "Replace with backup",
    input: { snapshot_id: 8, mode: "replace" },
    parsedResult: { loaded: true, elements_added: 6, auto_saved_snapshot_id: 4, snapshot_id: 8, mode: "replace", chat_session_id: 12, version: 3 },
    sourceType: "generic"
  },
  {
    id: "not_found",
    label: "Snapshot not found",
    input: { snapshot_id: 404, mode: "merge" },
    resultBody: "Couldn't find Whiteboard::Snapshot with 'id'=404",
    resultError: true,
    sourceType: "generic"
  }
]

const loadCanvasToolCard: ToolCardRenderer = {
  toolName: "load_canvas",
  collapsedSummary,
  renderExpanded
}

export default loadCanvasToolCard
