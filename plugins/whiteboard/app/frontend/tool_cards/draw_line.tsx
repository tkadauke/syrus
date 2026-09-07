import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { ElementActionCard, elementActionSummary, parseElementResult } from "../whiteboardToolCard"

// Plugin-owned tool card for draw_line (EPIC-292 / JOB-4223).
const ACTION = "Drew line"

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

const drawLineToolCard: ToolCardRenderer = {
  toolName: "draw_line",
  collapsedSummary,
  renderExpanded
}

export default drawLineToolCard
