import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import { parseTagAction, TagActionCard, tagActionSummary } from "../issueTagArtifactToolCard"

function collapsedSummary(context: ToolCardContext) {
  const result = parseTagAction(context, "remove")
  return result ? tagActionSummary(result) : null
}

function renderExpanded(context: ToolCardContext) {
  const result = parseTagAction(context, "remove")
  return result ? <TagActionCard result={result} /> : null
}

const removeJobTagToolCard: ToolCardRenderer = {
  toolName: "remove_job_tag",
  collapsedSummary,
  renderExpanded
}

export default removeJobTagToolCard

export const examples: ToolCardExample[] = [
  {
    id: "resolved_from_tag_list",
    label: "Tag removed with resolved name",
    description: "Resolves the tag name and color from an earlier list_tags result.",
    input: { job_id: 7, tag_id: 10 },
    parsedResult: { success: true },
    priorResults: { list_tags: { tags: [{ id: 10, name: "area:ui", color: "blue", job_ids: [7] }] } }
  },
  {
    id: "tag_not_attached_error",
    label: "Tag not attached error",
    input: { job_id: 7, tag_id: 10 },
    parsedResult: { error: "tag is not attached to JOB-7" },
    resultError: true
  },
  {
    id: "unknown_tag_error",
    label: "Unknown tag error",
    input: { job_id: 7, tag_id: 99 },
    parsedResult: { error: "tag not found for this user: 99" },
    resultError: true
  },
  {
    id: "empty_result",
    label: "Completed with an empty result",
    description: "Shows a settled empty provider response as unexpected rather than leaving the action pending.",
    input: { job_id: 7, tag_id: 10 },
    resultBody: "",
    resultSettled: true
  },
  { id: "pending", label: "Pending", input: { job_id: 7, tag_id: 10 }, resultSettled: false }
]
