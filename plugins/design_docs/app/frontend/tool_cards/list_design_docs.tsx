import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"

// Demonstrates the plugin-owned tool-card extension point (EPIC-291 /
// JOB-4219): this file lives entirely inside the design_docs plugin and is
// discovered by core's directory-convention glob (see
// app/frontend/pluginToolCards.tsx) — core never imports this module by
// name, so this card can be added, changed, or removed without touching any
// central renderer list.
type DesignDocListItem = {
  id?: unknown
  doc_ref?: unknown
  title?: unknown
  state?: unknown
}

function designDocs(context: ToolCardContext): DesignDocListItem[] | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed) || !Array.isArray(parsed.design_docs)) return null

  return parsed.design_docs.filter(isPlainObject) as DesignDocListItem[]
}

function collapsedSummary(context: ToolCardContext) {
  const docs = designDocs(context)
  if (!docs) return null

  return `${docs.length} design doc${docs.length === 1 ? "" : "s"}`
}

function renderExpanded(context: ToolCardContext) {
  const docs = designDocs(context)
  if (!docs || docs.length === 0) return null

  return (
    <ul className="mt-1 space-y-1 rounded border border-gray-200 bg-gray-50 p-2 text-xs dark:border-gray-700 dark:bg-gray-900">
      {docs.map((doc, index) => {
        const docRef = typeof doc.doc_ref === "string" && doc.doc_ref ? doc.doc_ref : String(doc.id ?? index)
        const title = typeof doc.title === "string" && doc.title ? doc.title : "Untitled design doc"
        const state = typeof doc.state === "string" ? doc.state : null

        return (
          <li className="flex items-center gap-2" key={docRef}>
            <span className="shrink-0 font-mono font-medium text-gray-700 dark:text-gray-300">{docRef}</span>
            <span className="min-w-0 flex-1 truncate text-gray-800 dark:text-gray-100">{title}</span>
            {state ? (
              <span className="shrink-0 rounded-full bg-gray-100 px-2 py-0.5 text-2xs uppercase text-gray-500 dark:bg-gray-800 dark:text-gray-400">
                {state}
              </span>
            ) : null}
          </li>
        )
      })}
    </ul>
  )
}

const listDesignDocsToolCard: ToolCardRenderer = {
  toolName: "list_design_docs",
  collapsedSummary,
  renderExpanded
}

export default listDesignDocsToolCard
