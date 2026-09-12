import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { ElementActionCard, ElementFailureCard, elementActionSummary, elementFailureSummary, parseElementResult, t } from "../whiteboardToolCard"

// Plugin-owned tool card for draw_shape (the pending-action tool-card work). Lives entirely
// inside the whiteboard plugin -- core discovers it by directory convention
// (see app/frontend/pluginToolCards.tsx) and never imports it by name, so it
// can be added, changed, or removed without touching core.
const ACTION_KEY = "tool_action_drew_shape"

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

const drawShapeToolCard: ToolCardRenderer = {
  toolName: "draw_shape",
  collapsedSummary,
  renderExpanded
}

export default drawShapeToolCard
