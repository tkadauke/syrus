import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { Badge, CardShell, displayValue, EmptyState, EntityReference, FilterableList, numberValue, Row, StatePill } from "@app/routes/chat/toolCardUi"
import { DesignDocErrorCard, DesignDocPendingCard, t } from "../designDocToolCard"

// Demonstrates the plugin-owned tool-card extension point (the Tier 1 tool-card work /
// the plugin boundary): this file lives entirely inside the design_docs plugin and is
// discovered by core's directory-convention glob (see
// app/frontend/pluginToolCards.tsx) — core never imports this module by
// name, so this card can be added, changed, or removed without touching any
// central renderer list.
type DesignDocListItem = {
  id?: unknown
  doc_ref?: unknown
  title?: unknown
  state?: unknown
  visibility?: unknown
  repository_ids?: unknown
  current_version_number?: unknown
  updated_at?: unknown
}

function designDocs(context: ToolCardContext): DesignDocListItem[] | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed) || !Array.isArray(parsed.design_docs)) return null

  return parsed.design_docs.filter(isPlainObject) as DesignDocListItem[]
}

function collapsedSummary(context: ToolCardContext) {
  if (context.resultError) return t("tool_list_error_summary")
  if (!context.resultBody && context.parsedResult == null) return t("tool_list_pending_summary")
  const docs = designDocs(context)
  if (!docs) return null

  return t("tool_design_doc_count", { count: docs.length })
}

function renderExpanded(context: ToolCardContext) {
  if (context.resultError) {
    return <DesignDocErrorCard message={displayValue(context.resultBody) ?? t("tool_unknown_error")} title={t("tool_list_title")} />
  }
  if (!context.resultBody && context.parsedResult == null) return <DesignDocPendingCard title={t("tool_list_title")} />

  const docs = designDocs(context)
  if (!docs) return null

  const filters = [
    context.input?.query != null ? { label: t("tool_filter_query"), value: String(context.input.query) } : null,
    context.input?.limit != null ? { label: t("tool_filter_limit"), value: String(context.input.limit) } : null
  ].filter((filter): filter is { label: string; value: string } => filter !== null)
  const repositoryId = numberValue(context.input?.repository_id)

  return (
    <CardShell>
      {filters.length > 0 || repositoryId != null ? (
        <div className="flex flex-wrap items-end gap-3">
          {filters.map((filter) => (
            <Row key={filter.label} label={filter.label} value={filter.value} />
          ))}
          {repositoryId != null ? (
            <div>
              <div className="text-2xs font-medium text-text-muted">{t("tool_filter_repository")}</div>
              <EntityReference kind="repository" label={t("tool_repository_number", { id: repositoryId })} repositoryId={repositoryId} />
            </div>
          ) : null}
        </div>
      ) : null}
      {docs.length === 0 ? (
        <EmptyState>{t("tool_no_design_docs")}</EmptyState>
      ) : (
        <FilterableList
          emptyLabel={t("tool_no_matching_design_docs")}
          itemText={(doc) =>
            [doc.doc_ref, doc.id, doc.title, doc.state, doc.visibility, ...(Array.isArray(doc.repository_ids) ? doc.repository_ids : [])]
              .filter(Boolean)
              .join(" ")
          }
          items={docs}
          placeholder={t("list_tool_filter_placeholder")}
        >
          {(visibleDocs) => (
            <ul className="space-y-2 rounded-[var(--radius-panel)] border border-border bg-surface p-2 text-xs">
              {visibleDocs.map((doc, index) => {
                const docId = numberValue(typeof doc.doc_ref === "string" ? doc.doc_ref.match(/(\d+)\s*$/)?.[1] : null) ?? numberValue(doc.id)
                const docRef = typeof doc.doc_ref === "string" && doc.doc_ref ? doc.doc_ref : String(doc.id ?? index)
                const title = typeof doc.title === "string" && doc.title ? doc.title : t("tool_untitled_design_doc")
                const state = typeof doc.state === "string" ? doc.state : null
                const visibility = displayValue(doc.visibility)
                const version = numberValue(doc.current_version_number)
                const updatedAt = displayValue(doc.updated_at)
                const repositoryIds = Array.isArray(doc.repository_ids) ? doc.repository_ids.map(numberValue).filter((id): id is number => id !== null) : []

                return (
                  <li
                    className="flex min-w-0 flex-col gap-1 border-b border-border pb-2 last:border-b-0 last:pb-0 sm:flex-row sm:items-start sm:gap-2"
                    key={docRef}
                  >
                    <EntityReference id={docId} kind="design_doc" label={docRef} slug={docRef} wrap="nowrap" />
                    <div className="min-w-0 flex-1">
                      <div className="whitespace-normal break-words font-medium text-text-primary">{title}</div>
                      <div className="mt-1 flex flex-wrap items-center gap-1 text-text-muted">
                        {state ? <StatePill state={state} /> : null}
                        {visibility ? <Badge>{visibility}</Badge> : null}
                        {version != null ? <Badge>{t("tool_version", { number: version })}</Badge> : null}
                        {updatedAt ? <span>{t("tool_updated", { value: updatedAt })}</span> : null}
                      </div>
                      {repositoryIds.length > 0 ? (
                        <div className="mt-1 flex flex-wrap items-center gap-1">
                          <span className="text-text-muted">{t("tool_repositories")}</span>
                          {repositoryIds.map((id) => (
                            <EntityReference key={id} kind="repository" label={t("tool_repository_number", { id })} repositoryId={id} />
                          ))}
                        </div>
                      ) : null}
                    </div>
                  </li>
                )
              })}
            </ul>
          )}
        </FilterableList>
      )}
    </CardShell>
  )
}

const listDesignDocsToolCard: ToolCardRenderer = {
  toolName: "list_design_docs",
  collapsedSummary,
  renderExpanded
}

export default listDesignDocsToolCard

// Reviewable sample payloads for the Tool Card Catalog (a later Job) — see
// pluginToolCards.tsx's ToolCardExample.
export const examples = [
  {
    id: "three_design_docs",
    label: "Three Design Docs",
    parsedResult: {
      design_docs: [
        {
          id: 29,
          doc_ref: "DOC-29",
          title: "Public Release Readiness: Open-Source Launch Checklist",
          state: "draft",
          visibility: "public",
          current_version_number: 9,
          updated_at: "2026-10-18T10:00:00Z",
          repository_ids: [1]
        },
        {
          id: 26,
          doc_ref: "DOC-26",
          title: "Distributed Workflow DAG Execution",
          state: "draft",
          visibility: "private",
          current_version_number: 5,
          updated_at: "2026-10-17T10:00:00Z",
          repository_ids: [1, 2]
        },
        {
          id: 10,
          doc_ref: "DOC-10",
          title: "Job Backlog",
          state: "archived",
          visibility: "public",
          current_version_number: 8,
          updated_at: "2026-10-16T10:00:00Z",
          repository_ids: []
        }
      ]
    },
    input: { query: "workflow", repository_id: 1, limit: 20 }
  },
  {
    id: "no_design_docs",
    label: "No Design Docs",
    description: "Empty result set with the card's dedicated empty state.",
    parsedResult: { design_docs: [] }
  },
  {
    id: "invalid_repository",
    label: "Invalid Repository",
    resultBody: "Error: repository not found in this agent context: 999",
    resultError: true
  }
]
