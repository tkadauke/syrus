import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { ElementActionCard, elementActionSummary, parseElementResult } from "../whiteboardToolCard"

// Plugin-owned tool card for draw_freedraw (the pending-action tool-card work).
const ACTION = "Drew freehand path"

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

const drawFreedrawToolCard: ToolCardRenderer = {
  toolName: "draw_freedraw",
  collapsedSummary,
  renderExpanded
}

export default drawFreedrawToolCard
