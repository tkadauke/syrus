import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { ElementActionCard, ElementFailureCard, elementActionSummary, elementFailureSummary, parseElementResult, t } from "../whiteboardToolCard"

// Plugin-owned tool card for draw_image (the pending-action tool-card work). The tool
// result also carries a file_id (see draw_image_tool.rb), but parseElementResult
// only needs `id`/`version` -- the raw JSON "Raw details" disclosure still
// carries the file_id for anyone who needs it.
const ACTION_KEY = "tool_action_drew_image"

function collapsedSummary(context: ToolCardContext) {
  const failureSummary = elementFailureSummary(context, t(ACTION_KEY))
  if (failureSummary) return failureSummary

  const result = parseElementResult(context.parsedResult)
  if (!result) return null

  return elementActionSummary(t(ACTION_KEY), result, isPlainObject(context.input) ? context.input : undefined)
}

function renderExpanded(context: ToolCardContext) {
  if (context.resultError) return <ElementFailureCard action={t(ACTION_KEY)} context={context} />

  const result = parseElementResult(context.parsedResult)
  if (!result) return null

  return <ElementActionCard action={t(ACTION_KEY)} input={isPlainObject(context.input) ? context.input : undefined} result={result} />
}

const drawImageToolCard: ToolCardRenderer = {
  toolName: "draw_image",
  collapsedSummary,
  renderExpanded
}

export default drawImageToolCard
