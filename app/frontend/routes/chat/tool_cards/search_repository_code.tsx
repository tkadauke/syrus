import i18n from "@app/i18n"
import { isPlainObject, type ToolCardContext, type ToolCardExample, type ToolCardRenderer } from "@app/pluginToolCards"
import { Badge, EmptyState } from "../toolCardUi"

function payload(context: ToolCardContext): (Record<string, unknown> & { results: unknown[] }) | null {
  const result = context.parsedResult
  return isPlainObject(result) && Array.isArray(result.results) ? { ...result, results: result.results } : null
}

function collapsedSummary(context: ToolCardContext) {
  const result = payload(context)
  if (!result) return null
  if (result.incomplete === true) return i18n.t("chat:tool_card_repository_search_incomplete_summary", { count: result.results.length })
  return i18n.t("chat:tool_card_repository_search_complete_summary", { count: result.results.length })
}

function renderExpanded(context: ToolCardContext) {
  const result = payload(context)
  if (!result) return null
  const coverage = isPlainObject(result.coverage) ? result.coverage : {}
  return (
    <div className="space-y-2 text-sm">
      {result.incomplete === true && (
        <div className="rounded-md border border-border bg-surface-muted p-3 text-text-primary">
          <div className="font-semibold">{i18n.t("chat:tool_card_repository_search_incomplete")}</div>
          <div>{String(result.hint || i18n.t("chat:tool_card_repository_search_retry"))}</div>
        </div>
      )}
      <div className="flex flex-wrap gap-1">
        <Badge>{i18n.t("chat:tool_card_repository_search_status", { status: String(result.status || "unknown") })}</Badge>
        {typeof result.reason === "string" && result.reason && (
          <Badge>{i18n.t("chat:tool_card_repository_search_reason", { reason: result.reason })}</Badge>
        )}
        <Badge>
          {i18n.t("chat:tool_card_repository_search_coverage", {
            searched: String(coverage.searched_files ?? 0),
            candidates: String(coverage.candidate_files ?? "?")
          })}
        </Badge>
      </div>
      {result.results.length === 0 && (
        <EmptyState>
          {result.incomplete === true ? i18n.t("chat:tool_card_repository_search_no_match_partial") : i18n.t("chat:tool_card_repository_search_no_match")}
        </EmptyState>
      )}
    </div>
  )
}

const searchRepositoryCodeToolCard: ToolCardRenderer = { toolName: "search_repository_code", collapsedSummary, renderExpanded }
export default searchRepositoryCodeToolCard

export const examples: ToolCardExample[] = [
  {
    id: "inconclusive",
    label: "Incomplete search",
    input: { query: "class Widget" },
    parsedResult: {
      status: "inconclusive",
      incomplete: true,
      reason: "time_budget",
      results: [],
      hint: "Search is incomplete; no match means no match in the searched portion only. Narrow path or retry.",
      coverage: { candidate_files: 812, searched_files: 127 }
    }
  }
]
