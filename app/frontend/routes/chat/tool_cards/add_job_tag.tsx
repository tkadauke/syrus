import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import { parseTagAction, TagActionCard, tagActionSummary } from "../issueTagArtifactToolCard"

function collapsedSummary(context: ToolCardContext) {
  const result = parseTagAction(context, "add")
  return result ? tagActionSummary(result) : null
}

function renderExpanded(context: ToolCardContext) {
  const result = parseTagAction(context, "add")
  return result ? <TagActionCard result={result} /> : null
}

const addJobTagToolCard: ToolCardRenderer = {
  toolName: "add_job_tag",
  collapsedSummary,
  renderExpanded
}

export default addJobTagToolCard

export const examples: ToolCardExample[] = [
  {
    id: "resolved_from_tag_list",
    label: "Tag added with resolved name",
    description: "Resolves the tag name and color from an earlier list_tags result.",
    input: { job_id: 7, tag_id: 10 },
    parsedResult: { success: true },
    priorResults: { list_tags: { tags: [{ id: 10, name: "area:ui", color: "blue", job_ids: [] }] } }
  },
  {
    id: "unknown_tag_error",
    label: "Unknown tag error",
    input: { job_id: 7, tag_id: 99 },
    parsedResult: { error: "tag not found for this user: 99" },
    resultError: true
  },
  { id: "pending", label: "Pending", input: { job_id: 7, tag_id: 10 }, resultSettled: false }
]
