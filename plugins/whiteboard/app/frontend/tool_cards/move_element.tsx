import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { ElementActionCard, elementActionSummary, parseElementResult } from "../whiteboardToolCard"

// Plugin-owned tool card for move_element (EPIC-292 / JOB-4223).
const ACTION = "Moved element"

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

const moveElementToolCard: ToolCardRenderer = {
  toolName: "move_element",
  collapsedSummary,
  renderExpanded
}

export default moveElementToolCard
