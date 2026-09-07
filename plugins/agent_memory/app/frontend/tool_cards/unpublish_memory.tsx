import { type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { MemoryDetailBody, parseMemoryDetail } from "../memoryToolCard"

// Plugin-owned tool card for unpublish_memory (EPIC-293).
function collapsedSummary(context: ToolCardContext) {
  const memory = parseMemoryDetail(context)
  if (!memory) return null

  return `Unpublished memory #${memory.id}`
}

function renderExpanded(context: ToolCardContext) {
  const memory = parseMemoryDetail(context)
  if (!memory) return null

  return <MemoryDetailBody memory={memory} />
}

const unpublishMemoryToolCard: ToolCardRenderer = {
  toolName: "unpublish_memory",
  collapsedSummary,
  renderExpanded
}

export default unpublishMemoryToolCard
