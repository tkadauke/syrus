import { type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { MemoryDetailBody, parseMemoryDetail } from "../memoryToolCard"

// Plugin-owned tool card for write_memory (EPIC-293). write_memory's
// response is `{ id, memory: memory_payload }` -- the same detail shape
// read_memory/publish_memory/unpublish_memory share.
function collapsedSummary(context: ToolCardContext) {
  const memory = parseMemoryDetail(context)
  if (!memory) return null

  return `Wrote memory #${memory.id} (${memory.kind ?? "unknown"})`
}

function renderExpanded(context: ToolCardContext) {
  const memory = parseMemoryDetail(context)
  if (!memory) return null

  return <MemoryDetailBody memory={memory} />
}

const writeMemoryToolCard: ToolCardRenderer = {
  toolName: "write_memory",
  collapsedSummary,
  renderExpanded
}

export default writeMemoryToolCard
