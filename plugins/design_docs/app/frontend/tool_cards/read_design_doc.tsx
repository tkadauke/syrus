import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { CardShell, LargeTextPreview, Row } from "@app/routes/chat/toolCardUi"
import { contentMetadata, DesignDocHeader, parseDesignDocSummary, type DesignDocSummary } from "../designDocToolCard"

// Plugin-owned tool card for read_design_doc (the pending-action tool-card work). Lives
// entirely inside the design_docs plugin -- core discovers it by directory
// convention (see app/frontend/pluginToolCards.tsx) and never imports it by
// name, so it can be added, changed, or removed without touching core.
type ReadDesignDoc = { summary: DesignDocSummary; markdown: unknown }

function readDesignDoc(context: ToolCardContext): ReadDesignDoc | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed) || !isPlainObject(parsed.design_doc)) return null

  const summary = parseDesignDocSummary(parsed.design_doc)
  if (!summary) return null

  return { summary, markdown: parsed.design_doc.markdown }
}

function collapsedSummary(context: ToolCardContext) {
  const doc = readDesignDoc(context)
  if (!doc) return null

  return `${doc.summary.docRef} — ${doc.summary.title}`
}

function renderExpanded(context: ToolCardContext) {
  const doc = readDesignDoc(context)
  if (!doc) return null

  const metadata = contentMetadata(doc.markdown)

  return (
    <CardShell>
      <DesignDocHeader doc={doc.summary} />
      <div className="text-sm font-medium text-gray-900 dark:text-gray-100">{doc.summary.title}</div>
      <dl className="grid gap-1 sm:grid-cols-2">
        {doc.summary.pendingSuggestionsCount != null ? (
          <Row label="Pending suggestions" value={String(doc.summary.pendingSuggestionsCount)} />
        ) : null}
        {doc.summary.openThreadsCount != null ? <Row label="Open threads" value={String(doc.summary.openThreadsCount)} /> : null}
        {metadata ? <Row label="Content" value={metadata} /> : null}
      </dl>
      {typeof doc.markdown === "string" && doc.markdown.trim() ? (
        <LargeTextPreview label="Markdown preview" maxLines={50} text={doc.markdown} />
      ) : null}
    </CardShell>
  )
}

const readDesignDocToolCard: ToolCardRenderer = {
  toolName: "read_design_doc",
  collapsedSummary,
  renderExpanded
}

export default readDesignDocToolCard
