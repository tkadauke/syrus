import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { Badge, CardShell, displayValue } from "@app/routes/chat/toolCardUi"
import { DesignDocHeader, parseDesignDocSummary, t, type DesignDocSummary } from "../designDocToolCard"

// Plugin-owned tool card for propose_design_doc (the pending-action tool-card work).
// propose_design_doc only ever creates a new draft doc (mutation_mode is
// always "new_doc_created"), so the card leads with that outcome.
type ProposeDesignDoc = { summary: DesignDocSummary; note: string | null }

function proposeDesignDoc(context: ToolCardContext): ProposeDesignDoc | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed) || !isPlainObject(parsed.design_doc)) return null

  const summary = parseDesignDocSummary(parsed.design_doc)
  if (!summary) return null

  return { summary, note: displayValue(parsed.note) }
}

function collapsedSummary(context: ToolCardContext) {
  const result = proposeDesignDoc(context)
  if (!result) return null

  return t("tool_created_summary", { doc: result.summary.docRef, title: result.summary.title })
}

function renderExpanded(context: ToolCardContext) {
  const result = proposeDesignDoc(context)
  if (!result) return null

  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <Badge>{t("tool_created")}</Badge>
      </div>
      <DesignDocHeader doc={result.summary} />
      <div className="text-sm font-medium text-gray-900 dark:text-gray-100">{result.summary.title}</div>
      {result.note ? <div className="text-gray-600 dark:text-gray-300">{result.note}</div> : null}
    </CardShell>
  )
}

const proposeDesignDocToolCard: ToolCardRenderer = {
  toolName: "propose_design_doc",
  collapsedSummary,
  renderExpanded
}

export default proposeDesignDocToolCard
