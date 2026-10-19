import { isPlainObject, type ToolCardContext, type ToolCardExample, type ToolCardRenderer } from "@app/pluginToolCards"
import { Badge, CardShell, displayValue, EmptyState, EntityReference, numberValue, Row, SectionLabel, StatePill } from "@app/routes/chat/toolCardUi"
import { MarkdownPreview } from "@app/routes/chat/toolCardMarkdown"
import { DesignDocErrorCard, DesignDocHeader, DesignDocPendingCard, parseDesignDocSummary, t, type DesignDocSummary } from "../designDocToolCard"

type RecordValue = Record<string, unknown>
type ReadDesignDoc = { summary: DesignDocSummary; value: RecordValue; envelope: RecordValue }

function payloadCandidate(parsed: RecordValue): { value: RecordValue; envelope: RecordValue } | null {
  if (isPlainObject(parsed.design_doc)) return { value: parsed.design_doc, envelope: parsed }
  for (const key of ["result", "data", "payload"]) {
    const envelope = parsed[key]
    if (isPlainObject(envelope) && isPlainObject(envelope.design_doc)) return { value: envelope.design_doc, envelope }
  }
  return null
}

function readDesignDoc(context: ToolCardContext): ReadDesignDoc | null {
  if (!isPlainObject(context.parsedResult)) return null
  const candidate = payloadCandidate(context.parsedResult)
  if (!candidate) return null
  const summary = parseDesignDocSummary(candidate.value)
  return summary ? { summary, ...candidate } : null
}

function objects(value: unknown): RecordValue[] {
  return Array.isArray(value) ? value.filter(isPlainObject) : []
}

function userLabel(value: unknown): string | null {
  if (!isPlainObject(value)) return displayValue(value)
  return (
    displayValue(value.name) ??
    displayValue(value.email_address) ??
    (numberValue(value.id) != null ? t("tool_user_number", { id: numberValue(value.id) }) : null)
  )
}

function anchorLabel(value: unknown): string | null {
  if (!isPlainObject(value)) return null
  return displayValue(value.selected_markdown) ?? displayValue(value.selected_text) ?? displayValue(value.anchor_key)
}

function MarkdownSection({ text, title }: { text: unknown; title: string }) {
  return typeof text === "string" ? <MarkdownPreview linkifySlugs linkifyUrls maxChars={1_200} text={text} title={title} /> : null
}

function DiscussionList({ items, kind }: { items: RecordValue[]; kind: "thread" | "suggestion" }) {
  if (items.length === 0) return <EmptyState>{kind === "thread" ? t("tool_no_threads") : t("tool_no_suggestions")}</EmptyState>
  return (
    <ul className="space-y-2">
      {items.map((item, index) => {
        const author = userLabel(kind === "thread" ? item.opened_by : item.suggested_by)
        const anchor = anchorLabel(item.anchor)
        const comments = kind === "thread" ? objects(item.comments) : []
        const body = kind === "suggestion" ? (item.proposed_markdown ?? item.suggested_markdown) : null
        return (
          <li className="min-w-0 rounded-[var(--radius-panel)] border border-border bg-surface p-2" key={displayValue(item.id) ?? index}>
            <div className="flex flex-wrap items-center gap-2">
              <span className="font-medium text-text-primary">
                {kind === "thread" ? t("tool_thread_number", { id: item.id ?? index + 1 }) : t("tool_suggestion_number", { id: item.id ?? index + 1 })}
              </span>
              {displayValue(item.state) ? <StatePill state={displayValue(item.state)!} /> : null}
              {author ? <span className="break-words text-xs text-text-muted">{author}</span> : null}
            </div>
            {anchor ? <MarkdownSection text={anchor} title={t("tool_anchor")} /> : null}
            {body != null ? <MarkdownSection text={body} title={t("tool_suggested_markdown")} /> : null}
            {comments.map((comment, commentIndex) => (
              <div className="mt-2 min-w-0 border-t border-border pt-2" key={displayValue(comment.id) ?? commentIndex}>
                {userLabel(comment.author) ? <div className="mb-1 break-words text-2xs text-text-muted">{userLabel(comment.author)}</div> : null}
                <MarkdownSection text={comment.body} title={t("tool_comment")} />
              </div>
            ))}
          </li>
        )
      })}
    </ul>
  )
}

function collapsedSummary(context: ToolCardContext) {
  const doc = readDesignDoc(context)
  if (context.resultError && !doc) return t("tool_read_error_summary")
  if (!context.resultBody && context.parsedResult == null) return t("tool_read_pending_summary")
  return doc ? `${doc.summary.docRef} — ${doc.summary.title}` : null
}

function renderExpanded(context: ToolCardContext) {
  const doc = readDesignDoc(context)
  if (context.resultError && !doc)
    return <DesignDocErrorCard message={displayValue(context.resultBody) ?? t("tool_unknown_error")} title={t("tool_read_title")} />
  if (!context.resultBody && context.parsedResult == null) return <DesignDocPendingCard title={t("tool_read_title")} />
  if (!doc) return null

  const mode = displayValue(context.input?.detail) ?? "full"
  const repositories = objects(doc.value.repositories)
  const repositoryIds = Array.isArray(doc.value.repository_ids) ? doc.value.repository_ids.map(numberValue).filter((id): id is number => id != null) : []
  const linkedRepositories: RecordValue[] = repositories.length > 0 ? repositories : repositoryIds.map((id) => ({ id }))
  const collaborators = objects(doc.value.collaborators)
    .map(userLabel)
    .filter((name): name is string => Boolean(name))
  const permissions = isPlainObject(doc.value.permissions) ? Object.entries(doc.value.permissions) : []
  const readOnly = doc.envelope.read_only === true
  const version = numberValue(doc.value.current_version_number)
  const updatedAt = displayValue(doc.value.updated_at)
  const markdown = typeof doc.value.markdown === "string" ? doc.value.markdown : null

  return (
    <CardShell>
      <DesignDocHeader doc={doc.summary} />
      <div className="break-words text-sm font-medium text-text-primary">{doc.summary.title}</div>
      <div className="flex flex-wrap items-center gap-1">
        <Badge>{t("tool_detail_mode", { mode })}</Badge>
        {version != null ? <Badge>{t("tool_version", { number: version })}</Badge> : null}
        {readOnly ? <Badge>{t("tool_read_only")}</Badge> : null}
        {updatedAt ? <span className="break-words text-xs text-text-muted">{t("tool_updated", { value: updatedAt })}</span> : null}
      </div>
      <dl className="grid gap-1 sm:grid-cols-2">
        {doc.summary.pendingSuggestionsCount != null ? <Row label={t("tool_pending_suggestions")} value={String(doc.summary.pendingSuggestionsCount)} /> : null}
        {doc.summary.openThreadsCount != null ? <Row label={t("tool_open_threads")} value={String(doc.summary.openThreadsCount)} /> : null}
      </dl>
      {repositories.length > 0 || repositoryIds.length > 0 ? (
        <div>
          <SectionLabel>{t("tool_repositories")}</SectionLabel>
          <div className="flex flex-wrap gap-2">
            {linkedRepositories.map((repository, index) => {
              const id = numberValue(repository.id)
              return (
                <EntityReference
                  href={displayValue(repository.repository_path)}
                  key={id ?? index}
                  kind="repository"
                  label={displayValue(repository.slug) ?? t("tool_repository_number", { id })}
                  repositoryId={id}
                />
              )
            })}
          </div>
        </div>
      ) : null}
      {collaborators.length > 0 ? (
        <div>
          <SectionLabel>{t("tool_collaborators")}</SectionLabel>
          <div className="flex flex-wrap gap-1">
            {collaborators.map((name) => (
              <Badge key={name}>{name}</Badge>
            ))}
          </div>
        </div>
      ) : null}
      {permissions.length > 0 ? (
        <div>
          <SectionLabel>{t("tool_permissions")}</SectionLabel>
          <div className="flex flex-wrap gap-1">
            {permissions.map(([name, allowed]) => (
              <Badge key={name}>
                {name.replace(/^can_/, "").replaceAll("_", " ")}: {allowed === true ? t("tool_yes") : t("tool_no")}
              </Badge>
            ))}
          </div>
        </div>
      ) : null}
      {mode === "summary" ? (
        <EmptyState>{t("tool_summary_mode_notice")}</EmptyState>
      ) : (
        <MarkdownPreview
          emptyState={<EmptyState>{t("tool_no_markdown")}</EmptyState>}
          linkifySlugs
          linkifyUrls
          maxChars={2_400}
          text={markdown ?? ""}
          title={t("tool_content")}
        />
      )}
      {mode !== "summary" ? (
        <div>
          <SectionLabel>{t("tool_threads")}</SectionLabel>
          <DiscussionList items={objects(doc.value.threads)} kind="thread" />
        </div>
      ) : null}
      {mode !== "summary" ? (
        <div>
          <SectionLabel>{t("tool_suggestions")}</SectionLabel>
          <DiscussionList items={objects(doc.value.suggestions)} kind="suggestion" />
        </div>
      ) : null}
    </CardShell>
  )
}

const readDesignDocToolCard: ToolCardRenderer = { toolName: "read_design_doc", collapsedSummary, renderExpanded }
export default readDesignDocToolCard

export const examples: ToolCardExample[] = [
  {
    id: "full_document",
    label: "Full design doc",
    input: { doc_ref: "DOC-20", detail: "full" },
    parsedResult: {
      design_doc: {
        doc_ref: "DOC-20",
        title: "Target graphs",
        visibility: "public",
        state: "draft",
        current_version_number: 3,
        repository_ids: [1],
        collaborators: [{ id: 2, name: "Ada" }],
        markdown: "# Plan\nSee JOB-42 and https://example.test.",
        threads: [],
        suggestions: [],
        permissions: { can_suggest: true }
      },
      read_only: false
    }
  },
  {
    id: "summary_document",
    label: "Summary mode",
    input: { doc_ref: "DOC-20", detail: "summary" },
    parsedResult: { result: { design_doc: { doc_ref: "DOC-20", title: "Target graphs", visibility: "public", state: "draft", current_version_number: 3 } } }
  },
  { id: "read_error", label: "Read error", resultBody: "design doc not found", resultError: true }
]
