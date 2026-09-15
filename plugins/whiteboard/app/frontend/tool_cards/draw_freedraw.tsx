import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { ElementActionCard, ElementFailureCard, elementActionSummary, elementFailureSummary, parseElementResult, t } from "../whiteboardToolCard"

// Plugin-owned tool card for draw_freedraw (the pending-action tool-card work).
const ACTION_KEY = "tool_action_drew_freehand_path"

function collapsedSummary(context: ToolCardContext) {
  const action = t(ACTION_KEY)
  const failureSummary = elementFailureSummary(context, action)
  if (failureSummary) return failureSummary

  const result = parseElementResult(context.parsedResult)
  if (!result) return null

  return elementActionSummary(action, result, isPlainObject(context.input) ? context.input : undefined)
}

function renderExpanded(context: ToolCardContext) {
  const action = t(ACTION_KEY)
  if (context.resultError) return <ElementFailureCard action={action} context={context} />

  const result = parseElementResult(context.parsedResult)
  if (!result) return null

  return <ElementActionCard action={action} input={isPlainObject(context.input) ? context.input : undefined} result={result} />
}

const drawFreedrawToolCard: ToolCardRenderer = {
  toolName: "draw_freedraw",
  collapsedSummary,
  renderExpanded
}

export default drawFreedrawToolCard
