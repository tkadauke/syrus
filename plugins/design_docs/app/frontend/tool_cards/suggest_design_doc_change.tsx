import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { Badge, CardShell, displayValue, Row, StatePill } from "@app/routes/chat/toolCardUi"
import { DesignDocHeader, parseDesignDocSummary, type DesignDocSummary } from "../designDocToolCard"

// Plugin-owned tool card for suggest_design_doc_change (EPIC-292 / JOB-4223).
// Chat-agent content writes are always suggestion-only (see
// plugins/design_docs/app/services/design_docs/suggest_design_doc_change_tool.rb),
// so the card's job is to surface the suggestion's own outcome -- state,
// change type, and any conflict -- not the doc's full content.
type SuggestDesignDocChange = {
  summary: DesignDocSummary
  state: string | null
  changeType: string | null
  changeSummary: string | null
  conflictReason: string | null
}

function suggestDesignDocChange(context: ToolCardContext): SuggestDesignDocChange | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed) || !isPlainObject(parsed.design_doc) || !isPlainObject(parsed.suggestion)) return null

  const summary = parseDesignDocSummary(parsed.design_doc)
  if (!summary) return null

  const suggestion = parsed.suggestion
  return {
    summary,
    state: displayValue(suggestion.state),
    changeType: displayValue(suggestion.change_type),
    changeSummary: displayValue(suggestion.change_summary),
    conflictReason: displayValue(suggestion.conflict_reason)
  }
}

function collapsedSummary(context: ToolCardContext) {
  const result = suggestDesignDocChange(context)
  if (!result) return null

  const state = result.state ? ` (${result.state})` : ""
  return `Suggested change to ${result.summary.docRef}${state}`
}

function renderExpanded(context: ToolCardContext) {
  const result = suggestDesignDocChange(context)
  if (!result) return null

  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <Badge>Suggestion</Badge>
        {result.state ? <StatePill state={result.state} /> : null}
        {result.changeType ? <Badge>{result.changeType.replace(/_/g, " ")}</Badge> : null}
      </div>
      <DesignDocHeader doc={result.summary} />
      <div className="text-sm font-medium text-gray-900 dark:text-gray-100">{result.summary.title}</div>
      {result.changeSummary ? <Row label="Summary" value={result.changeSummary} /> : null}
      {result.conflictReason ? (
        <div className="rounded bg-amber-100 px-2 py-1 text-amber-800 dark:bg-amber-950/40 dark:text-amber-200">
          <span className="text-2xs font-semibold uppercase">Conflict</span>
          <div>{result.conflictReason}</div>
        </div>
      ) : null}
    </CardShell>
  )
}

const suggestDesignDocChangeToolCard: ToolCardRenderer = {
  toolName: "suggest_design_doc_change",
  collapsedSummary,
  renderExpanded
}

export default suggestDesignDocChangeToolCard
