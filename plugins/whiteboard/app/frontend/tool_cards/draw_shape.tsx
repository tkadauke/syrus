import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { ElementActionCard, elementActionSummary, parseElementResult } from "../whiteboardToolCard"

// Plugin-owned tool card for draw_shape (the pending-action tool-card work). Lives entirely
// inside the whiteboard plugin -- core discovers it by directory convention
// (see app/frontend/pluginToolCards.tsx) and never imports it by name, so it
// can be added, changed, or removed without touching core.
const ACTION = "Drew shape"

function collapsedSummary(context: ToolCardContext) {
  const result = parseElementResult(context.parsedResult)
  if (!result) return null

  return elementActionSummary(ACTION, result, isPlainObject(context.input) ? context.input : undefined)
}

function renderExpanded(context: ToolCardContext) {
  const result = parseElementResult(context.parsedResult)
  if (!result) return null

  return <ElementActionCard action={ACTION} input={isPlainObject(context.input) ? context.input : undefined} result={result} />
}

const drawShapeToolCard: ToolCardRenderer = {
  toolName: "draw_shape",
  collapsedSummary,
  renderExpanded
}

export default drawShapeToolCard
