import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import { parseTagAction, TagActionCard, tagActionSummary } from "../issueTagArtifactToolCard"
import i18n from "@app/i18n"

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
  renderExpanded,
  renderWhilePending: true
}

export default removeJobTagToolCard

export const examples: ToolCardExample[] = [
  {
    id: "resolved_from_tag_list",
    label: i18n.t("chat:mutation_example_tag_removed"),
    description: i18n.t("chat:mutation_example_tag_resolved_description"),
    input: { job_id: 7, tag_id: 10 },
    parsedResult: { success: true },
    priorResults: { list_tags: { tags: [{ id: 10, name: "area:ui", color: "blue", job_ids: [7] }] } }
  },
  {
    id: "tag_not_attached_error",
    label: i18n.t("chat:mutation_example_tag_not_attached"),
    input: { job_id: 7, tag_id: 10 },
    parsedResult: { error: "tag is not attached to JOB-7" },
    resultError: true
  },
  {
    id: "unknown_tag_error",
    label: i18n.t("chat:mutation_example_unknown_tag"),
    input: { job_id: 7, tag_id: 99 },
    parsedResult: { error: "tag not found for this user: 99" },
    resultError: true
  },
  {
    id: "empty_result",
    label: i18n.t("chat:mutation_example_empty_result"),
    description: i18n.t("chat:mutation_example_empty_result_description"),
    input: { job_id: 7, tag_id: 10 },
    resultBody: "",
    resultSettled: true
  },
  { id: "pending", label: i18n.t("chat:tool_card_example_pending"), input: { job_id: 7, tag_id: 10 }, resultBody: "", resultSettled: false }
]
