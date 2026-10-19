import { isPlainObject, type ToolCardContext, type ToolCardExample, type ToolCardRenderer } from "@app/pluginToolCards"
import { MarkdownPreview } from "@app/routes/chat/toolCardMarkdown"
import { Badge, CardShell, displayValue, EntityReference, numberValue, Row } from "@app/routes/chat/toolCardUi"
import { DesignDocErrorCard, DesignDocHeader, DesignDocPendingCard, parseDesignDocSummary, t, type DesignDocSummary } from "../designDocToolCard"

type RepositoryReference = { id: number; label: string }
type CollaboratorReference = { id: number | null; label: string }
type ProposeDesignDoc = {
  summary: DesignDocSummary
  markdown: string
  note: string | null
  repositories: RepositoryReference[]
  collaborators: CollaboratorReference[]
  version: number | null
}

function repositoryReferences(value: unknown): RepositoryReference[] {
  if (!Array.isArray(value)) return []
  return value.flatMap((repository) => {
    if (!isPlainObject(repository)) return []
    const id = numberValue(repository.id)
    if (id == null) return []
    return [{ id, label: displayValue(repository.slug) ?? displayValue(repository.name) ?? t("tool_repository_number", { id }) }]
  })
}

function collaboratorReferences(value: unknown): CollaboratorReference[] {
  if (!Array.isArray(value)) return []
  return value.flatMap((collaborator) => {
    if (!isPlainObject(collaborator)) return []
    const id = numberValue(collaborator.id)
    const label = displayValue(collaborator.name) ?? displayValue(collaborator.login) ?? (id == null ? null : t("tool_collaborator_number", { id }))
    return label ? [{ id, label }] : []
  })
}

function proposeDesignDoc(context: ToolCardContext): ProposeDesignDoc | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed) || !isPlainObject(parsed.design_doc)) return null

  const doc = parsed.design_doc
  const summary = parseDesignDocSummary({ ...doc, doc_ref: doc.doc_ref ?? doc.display_id })
  if (!summary) return null

  return {
    summary,
    markdown: typeof doc.markdown === "string" ? doc.markdown : "",
    note: displayValue(parsed.note),
    repositories: repositoryReferences(doc.repositories),
    collaborators: collaboratorReferences(doc.collaborators),
    version: numberValue(doc.current_version_number)
  }
}

function inputIds(value: unknown): number[] {
  if (!Array.isArray(value)) return []
  return value.map(numberValue).filter((id): id is number => id != null)
}

function collapsedSummary(context: ToolCardContext) {
  if (context.resultError) return t("tool_propose_error_summary")
  if (!context.resultBody && context.parsedResult == null) return t("tool_propose_pending_summary")
  const result = proposeDesignDoc(context)
  if (!result) return null
  return t("tool_created_summary", { doc: result.summary.docRef, title: result.summary.title })
}

function renderRepositoryList(repositories: RepositoryReference[]) {
  if (repositories.length === 0) return null
  return (
    <div className="flex min-w-0 flex-wrap items-center gap-1">
      <span className="text-xs text-text-muted">{t("tool_repositories")}</span>
      {repositories.map((repository) => (
        <EntityReference key={repository.id} kind="repository" label={repository.label} repositoryId={repository.id} />
      ))}
    </div>
  )
}

function renderExpanded(context: ToolCardContext) {
  if (context.resultError) {
    return <DesignDocErrorCard message={displayValue(context.resultBody) ?? t("tool_unknown_error")} title={t("tool_propose_title")} />
  }
  if (!context.resultBody && context.parsedResult == null) return <DesignDocPendingCard title={t("tool_propose_title")} />

  const result = proposeDesignDoc(context)
  if (!result) return null

  const input = isPlainObject(context.input) ? context.input : {}
  const proposedMarkdown = typeof input.markdown === "string" ? input.markdown : ""
  const changeSummary = typeof input.change_summary === "string" ? input.change_summary : ""
  const inputRepositoryIds = inputIds(input.repository_ids)
  const collaboratorIds = inputIds(input.collaborator_user_ids)
  const visibility = displayValue(input.visibility)

  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <Badge>{t("tool_created")}</Badge>
        {result.version != null ? <Badge>{t("tool_version", { number: result.version })}</Badge> : null}
      </div>
      <DesignDocHeader doc={result.summary} />
      <div className="break-words text-sm font-medium text-text-primary">{result.summary.title}</div>
      <div className="grid min-w-0 gap-2 sm:grid-cols-2">
        {visibility ? <Row label={t("visibility")} value={visibility} /> : null}
        {collaboratorIds.length > 0 ? <Row label={t("tool_collaborators")} value={collaboratorIds.join(", ")} /> : null}
      </div>
      {renderRepositoryList(inputRepositoryIds.map((id) => ({ id, label: t("tool_repository_number", { id }) })))}
      <MarkdownPreview emptyLabel={t("tool_no_change_summary")} linkifyUrls maxChars={320} maxLines={2} text={changeSummary} title={t("tool_summary")} />
      <MarkdownPreview emptyLabel={t("tool_no_proposed_content")} linkifyUrls maxChars={960} text={proposedMarkdown} title={t("tool_proposed_content")} />
      <div className="border-t border-border pt-2">
        <MarkdownPreview emptyLabel={t("tool_no_created_content")} linkifyUrls maxChars={960} text={result.markdown} title={t("tool_created_content")} />
      </div>
      {renderRepositoryList(result.repositories)}
      {result.collaborators.length > 0 ? (
        <Row label={t("tool_collaborators")} value={result.collaborators.map((collaborator) => collaborator.label).join(", ")} />
      ) : null}
      {result.note ? <MarkdownPreview linkifyUrls maxChars={320} maxLines={2} text={result.note} title={t("tool_note")} /> : null}
    </CardShell>
  )
}

const proposeDesignDocToolCard: ToolCardRenderer = { toolName: "propose_design_doc", collapsedSummary, renderExpanded }
export default proposeDesignDocToolCard

export const examples: ToolCardExample[] = [
  {
    id: "created_design_doc",
    label: "Created Design Doc",
    description: "A complete proposal with linked repositories, collaborators, and Markdown previews.",
    input: {
      title: "Worker placement",
      markdown: "# Worker placement\n\nRoute work for JOB-42 to https://example.test/workers.",
      visibility: "private",
      repository_ids: [1, 2],
      collaborator_user_ids: [7],
      change_summary: "Document the **placement** rules."
    },
    parsedResult: {
      design_doc: {
        id: 42,
        doc_ref: "DOC-42",
        title: "Worker placement",
        visibility: "private",
        state: "draft",
        current_version_number: 1,
        markdown: "# Worker placement\n\nRoute work to a capable worker.",
        repositories: [{ id: 1, slug: "acme/syrus" }],
        collaborators: [{ id: 7, name: "Ada" }]
      },
      note: "Use `suggest_design_doc_change` for later edits."
    }
  },
  { id: "permission_error", label: "Permission Error", resultBody: "Repository not attached to this chat context", resultError: true, sourceType: "codex" },
  { id: "pending", label: "Pending", description: "The tool call has not returned a result yet." }
]
