import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { ElementActionCard, elementActionSummary, parseElementResult, t } from "../whiteboardToolCard"

// Plugin-owned tool card for draw_arrow (the pending-action tool-card work).
const ACTION_KEY = "tool_action_drew_arrow"

function collapsedSummary(context: ToolCardContext) {
  const result = parseElementResult(context.parsedResult)
  if (!result) return null

  return elementActionSummary(t(ACTION_KEY), result, isPlainObject(context.input) ? context.input : undefined)
}

function renderExpanded(context: ToolCardContext) {
  const result = parseElementResult(context.parsedResult)
  if (!result) return null

  return <ElementActionCard action={t(ACTION_KEY)} input={isPlainObject(context.input) ? context.input : undefined} result={result} />
}

const drawArrowToolCard: ToolCardRenderer = {
  toolName: "draw_arrow",
  collapsedSummary,
  renderExpanded
}

export default drawArrowToolCard
