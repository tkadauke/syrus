import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import { parseTagAction, TagActionCard, tagActionSummary } from "../issueTagArtifactToolCard"
import i18n from "@app/i18n"

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
  renderExpanded,
  renderWhilePending: true
}

export default addJobTagToolCard

export const examples: ToolCardExample[] = [
  {
    id: "resolved_from_tag_list",
    get label() {
      return i18n.t("chat:mutation_example_tag_added")
    },
    get description() {
      return i18n.t("chat:mutation_example_tag_resolved_description")
    },
    input: { job_id: 7, tag_id: 10 },
    parsedResult: { success: true },
    priorResults: { list_tags: { tags: [{ id: 10, name: "area:ui", color: "blue", job_ids: [] }] } }
  },
  {
    id: "unknown_tag_error",
    get label() {
      return i18n.t("chat:mutation_example_unknown_tag")
    },
    input: { job_id: 7, tag_id: 99 },
    parsedResult: { error: "tag not found for this user: 99" },
    resultError: true
  },
  {
    id: "pending",
    get label() {
      return i18n.t("chat:tool_card_example_pending")
    },
    input: { job_id: 7, tag_id: 10 },
    resultBody: "",
    resultSettled: false
  }
]
