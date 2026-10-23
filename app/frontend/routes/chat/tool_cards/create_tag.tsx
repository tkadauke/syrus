import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import { parseTagAction, TagActionCard, tagActionSummary } from "../issueTagArtifactToolCard"

function collapsedSummary(context: ToolCardContext) {
  const result = parseTagAction(context, "create")
  return result ? tagActionSummary(result) : null
}

function renderExpanded(context: ToolCardContext) {
  const result = parseTagAction(context, "create")
  return result ? <TagActionCard result={result} /> : null
}

const createTagToolCard: ToolCardRenderer = {
  toolName: "create_tag",
  collapsedSummary,
  renderExpanded
}

export default createTagToolCard

export const examples: ToolCardExample[] = [
  {
    id: "palette_tag_created",
    label: "Palette tag created",
    input: { name: "area:ui", color: "blue" },
    parsedResult: { id: 10, name: "area:ui", color: "blue", job_ids: [] }
  },
  {
    id: "duplicate_name",
    label: "Duplicate name",
    input: { name: "area:ui", color: "gray" },
    resultBody: "Name has already been taken",
    resultError: true
  }
]
