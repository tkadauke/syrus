import { isPlainObject, type ToolCardContext, type ToolCardExample, type ToolCardRenderer } from "@app/pluginToolCards"
import { MarkdownPreview } from "@app/routes/chat/toolCardMarkdown"
import { Badge, CardShell, displayValue, EmptyState, InternalLink, numberValue, Row, StatePill } from "@app/routes/chat/toolCardUi"
import { DesignDocErrorCard, DesignDocHeader, parseDesignDocSummary, t, type DesignDocSummary } from "../designDocToolCard"

type CommentOnDesignDoc = {
  summary: DesignDocSummary
  threadId: number | null
  threadState: string | null
  selectedMarkdown: string
  startOffset: number | null
  endOffset: number | null
  commentId: number | null
  commentBody: string
  authorKind: string | null
  authorName: string | null
  isReply: boolean
  versionNumber: number | null
  mutationMode: string | null
}

function errorMessage(context: ToolCardContext) {
  const parsed = context.parsedResult
  if (isPlainObject(parsed)) return displayValue(parsed.error) ?? displayValue(parsed.message) ?? displayValue(parsed.detail)
  return displayValue(context.resultBody)
}

function commentOnDesignDoc(context: ToolCardContext): CommentOnDesignDoc | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed) || !isPlainObject(parsed.design_doc) || !isPlainObject(parsed.comment)) return null
  const summary = parseDesignDocSummary(parsed.design_doc)
  if (!summary) return null

  const thread = isPlainObject(parsed.thread) ? parsed.thread : {}
  const anchor = isPlainObject(thread.anchor) ? thread.anchor : {}
  const comment = parsed.comment
  const author = isPlainObject(comment.author) ? comment.author : {}
  const version = isPlainObject(parsed.version) ? parsed.version : {}
  const comments = Array.isArray(thread.comments) ? thread.comments.filter(isPlainObject) : []
  const commentId = numberValue(comment.id)

  return {
    summary,
    threadId: numberValue(thread.id),
    threadState: displayValue(thread.state),
    selectedMarkdown: displayValue(anchor.selected_markdown) ?? displayValue(context.input?.selected_markdown) ?? "",
    startOffset: numberValue(anchor.start_offset) ?? numberValue(context.input?.start_offset),
    endOffset: numberValue(anchor.end_offset) ?? numberValue(context.input?.end_offset),
    commentId,
    commentBody: displayValue(comment.body) ?? displayValue(context.input?.body) ?? "",
    authorKind: displayValue(comment.author_kind),
    authorName: displayValue(author.name) ?? displayValue(author.email_address),
    isReply: comments.some((entry) => numberValue(entry.id) !== commentId),
    versionNumber: numberValue(version.version_number),
    mutationMode: displayValue(parsed.mutation_mode)
  }
}

function inputDocRef(context: ToolCardContext) {
  return displayValue(context.input?.doc_ref)
}

function InputDetails({ context }: { context: ToolCardContext }) {
  const docRef = inputDocRef(context)
  const startOffset = numberValue(context.input?.start_offset)
  const endOffset = numberValue(context.input?.end_offset)
  const selectedMarkdown = displayValue(context.input?.selected_markdown) ?? ""
  const body = displayValue(context.input?.body) ?? ""

  return (
    <div className="min-w-0 space-y-2">
      {docRef ? <Row label={t("tool_design_doc")} value={docRef} /> : null}
      {startOffset != null && endOffset != null ? <Row label={t("tool_anchor_offsets")} value={`${startOffset}–${endOffset}`} /> : null}
      {selectedMarkdown ? <MarkdownPreview linkifyUrls maxChars={360} maxLines={3} text={selectedMarkdown} title={t("tool_selected_text")} /> : null}
      <MarkdownPreview emptyState={t("tool_empty_comment")} linkifyUrls maxChars={720} maxLines={6} text={body} title={t("tool_comment")} />
    </div>
  )
}

function collapsedSummary(context: ToolCardContext) {
  const result = commentOnDesignDoc(context)
  if (context.resultError && !result) return t("tool_comment_error_summary", { doc: inputDocRef(context) ?? t("tool_design_doc") })
  if (!context.resultBody && context.parsedResult == null) return t("tool_comment_pending_summary", { doc: inputDocRef(context) ?? t("tool_design_doc") })
  if (!result) return null
  return t(result.isReply ? "tool_replied_on" : "tool_commented_on", { doc: result.summary.docRef })
}

function renderExpanded(context: ToolCardContext) {
  const result = commentOnDesignDoc(context)
  if (context.resultError && !result) {
    return (
      <DesignDocErrorCard message={errorMessage(context) ?? t("tool_unknown_error")} title={t("tool_comment_error_title")}>
        <InputDetails context={context} />
      </DesignDocErrorCard>
    )
  }
  if (!context.resultBody && context.parsedResult == null) {
    return (
      <CardShell>
        <div className="flex flex-wrap items-center gap-2">
          <Badge>{t("tool_comment")}</Badge>
          <StatePill state="pending" />
        </div>
        <InputDetails context={context} />
        <EmptyState>{t("tool_pending")}</EmptyState>
      </CardShell>
    )
  }
  if (!result) return null

  const threadHref = `/design_docs/${result.summary.docRef.replace(/^DOC-/i, "")}#thread-${result.threadId}`
  const anchorLabel = result.startOffset != null && result.endOffset != null ? `${result.startOffset}–${result.endOffset}` : null
  const authorLabel = [result.authorName, result.authorKind].filter(Boolean).join(" · ")

  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <Badge>{result.isReply ? t("tool_reply") : t("tool_comment")}</Badge>
        {result.threadState ? <StatePill state={result.threadState} /> : null}
        {result.versionNumber != null ? <Badge>{t("tool_version", { number: result.versionNumber })}</Badge> : null}
        {result.mutationMode ? <Badge>{result.mutationMode.replace(/_/g, " ")}</Badge> : null}
      </div>
      <DesignDocHeader doc={result.summary} href={result.threadId == null ? undefined : threadHref} />
      <div className="break-words text-sm font-medium text-text-primary">{result.summary.title}</div>
      <div className="grid min-w-0 grid-cols-1 gap-2 sm:grid-cols-2">
        {result.threadId != null ? (
          <div className="min-w-0">
            <div className="text-2xs font-medium text-text-muted">{t("tool_thread")}</div>
            <InternalLink href={threadHref}>{t("tool_thread_number", { id: result.threadId })}</InternalLink>
          </div>
        ) : null}
        {result.commentId != null ? <Row label={t("tool_comment_id")} value={String(result.commentId)} /> : null}
        {authorLabel ? <Row label={t("tool_author")} value={authorLabel} /> : null}
        {anchorLabel ? <Row label={t("tool_anchor_offsets")} value={anchorLabel} /> : null}
      </div>
      {result.selectedMarkdown || anchorLabel ? (
        <blockquote className="min-w-0 border-l-2 border-brand/40 pl-2">
          <MarkdownPreview
            emptyState={t("tool_empty_selection")}
            linkifyUrls
            maxChars={360}
            maxLines={3}
            modalLabel={t("tool_selected_text")}
            text={result.selectedMarkdown}
            title={t("tool_selected_text")}
          />
        </blockquote>
      ) : null}
      <MarkdownPreview
        emptyState={t("tool_empty_comment")}
        linkifyUrls
        maxChars={720}
        maxLines={6}
        modalLabel={t("tool_full_comment")}
        text={result.commentBody}
        title={t("tool_comment")}
      />
    </CardShell>
  )
}

const commentOnDesignDocToolCard: ToolCardRenderer = { toolName: "comment_on_design_doc", collapsedSummary, renderExpanded }
export default commentOnDesignDocToolCard

const completeResult = {
  design_doc: { id: 20, doc_ref: "DOC-20", title: "Target Graphs", visibility: "public", state: "draft" },
  doc_ref: "DOC-20",
  thread: {
    id: 41,
    state: "open",
    anchor: { start_offset: 18, end_offset: 42, selected_markdown: "The **target graph** maps JOB-42." },
    comments: [{ id: 5, author_kind: "agent", body: "See https://example.test/design and DOC-29." }]
  },
  comment: { id: 5, author_kind: "agent", author: null, body: "See https://example.test/design and DOC-29." },
  version: { id: 9, version_number: 3 },
  mutation_mode: "comment_only"
}

export const examples: ToolCardExample[] = [
  {
    id: "anchored_comment",
    label: "Anchored Markdown comment",
    description: "Provider-neutral payload with author, anchor, thread, version, and mutation metadata.",
    input: {
      doc_ref: "DOC-20",
      body: completeResult.comment.body,
      start_offset: 18,
      end_offset: 42,
      selected_markdown: completeResult.thread.anchor.selected_markdown
    },
    parsedResult: completeResult,
    sourceType: "generic"
  },
  {
    id: "permission_error",
    label: "Permission error",
    input: { doc_ref: "DOC-20", body: "Restricted", start_offset: 0, end_offset: 0 },
    resultBody: "not allowed to comment on DOC-20",
    resultError: true,
    sourceType: "claude"
  },
  {
    id: "pending_comment",
    label: "Pending comment",
    input: { doc_ref: "DOC-20", body: "Still running", start_offset: 0, end_offset: 0 },
    resultBody: "",
    sourceType: "codex"
  }
]
