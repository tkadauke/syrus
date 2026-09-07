import { type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { MemoryDetailBody, parseMemoryDetail } from "../memoryToolCard"

// Plugin-owned tool card for read_memory (EPIC-293).
function collapsedSummary(context: ToolCardContext) {
  const memory = parseMemoryDetail(context)
  if (!memory) return null

  return `Memory #${memory.id} (${memory.kind ?? "unknown"})`
}

function renderExpanded(context: ToolCardContext) {
  const memory = parseMemoryDetail(context)
  if (!memory) return null

  return <MemoryDetailBody memory={memory} />
}

const readMemoryToolCard: ToolCardRenderer = {
  toolName: "read_memory",
  collapsedSummary,
  renderExpanded
}

export default readMemoryToolCard
