import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { ElementActionCard, elementActionSummary, parseElementResult } from "../whiteboardToolCard"

// Plugin-owned tool card for draw_image (the pending-action tool-card work). The tool
// result also carries a file_id (see draw_image_tool.rb), but parseElementResult
// only needs `id`/`version` -- the raw JSON "Raw details" disclosure still
// carries the file_id for anyone who needs it.
const ACTION = "Drew image"

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

const drawImageToolCard: ToolCardRenderer = {
  toolName: "draw_image",
  collapsedSummary,
  renderExpanded
}

export default drawImageToolCard
