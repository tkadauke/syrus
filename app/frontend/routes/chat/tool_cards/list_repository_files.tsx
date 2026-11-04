import i18n from "@app/i18n"
import { isPlainObject, type ToolCardContext, type ToolCardExample, type ToolCardRenderer } from "@app/pluginToolCards"
import { Badge } from "../toolCardUi"

function parsed(context: ToolCardContext) {
  return isPlainObject(context.parsedResult) && Array.isArray(context.parsedResult.entries) ? context.parsedResult : null
}

function collapsedSummary(context: ToolCardContext) {
  const result = parsed(context)
  if (!result) return null
  return result.incomplete === true
    ? i18n.t("chat:tool_card_repository_list_incomplete_summary", { count: result.entries.length })
    : i18n.t("chat:tool_card_repository_list_complete_summary", { count: result.entries.length })
}

function renderExpanded(context: ToolCardContext) {
  const result = parsed(context)
  if (!result) return null
  const coverage = isPlainObject(result.coverage) ? result.coverage : {}
  return (
    <div className="space-y-2 text-sm">
      {result.incomplete === true && (
        <div className="rounded-md border border-border bg-surface-muted p-3 text-text-primary">
          <div className="font-semibold">{i18n.t("chat:tool_card_repository_list_incomplete")}</div>
          <div>{String(result.hint || i18n.t("chat:tool_card_repository_search_retry"))}</div>
        </div>
      )}
      <div className="flex flex-wrap gap-1">
        <Badge>{i18n.t("chat:tool_card_repository_search_status", { status: String(result.status || "unknown") })}</Badge>
        {result.reason && <Badge>{i18n.t("chat:tool_card_repository_search_reason", { reason: String(result.reason) })}</Badge>}
        <Badge>
          {i18n.t("chat:tool_card_repository_list_coverage", {
            returned: String(coverage.returned_entries ?? result.entries.length),
            candidates: String(coverage.candidate_entries ?? "?")
          })}
        </Badge>
      </div>
    </div>
  )
}

const listRepositoryFilesToolCard: ToolCardRenderer = { toolName: "list_repository_files", collapsedSummary, renderExpanded }
export default listRepositoryFilesToolCard

export const examples: ToolCardExample[] = [
  {
    id: "incomplete",
    label: "Incomplete listing",
    parsedResult: {
      status: "incomplete",
      incomplete: true,
      reason: "result_limit",
      entries: [{ path: "app/models/widget.rb", type: "blob", size: 120 }],
      hint: "Listing is incomplete. Narrow path or retry.",
      coverage: { candidate_entries: 900, returned_entries: 500 }
    }
  }
]
