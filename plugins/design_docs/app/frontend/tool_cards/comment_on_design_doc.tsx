import { isPlainObject, type ToolCardContext, type ToolCardExample, type ToolCardRenderer } from "@app/pluginToolCards"
import { Badge, CardShell, displayValue, EmptyState, numberValue, Row, StatePill } from "@app/routes/chat/toolCardUi"
import { MarkdownPreview } from "@app/routes/chat/toolCardMarkdown"
import { DesignDocErrorCard, DesignDocPendingCard, parseDesignDocSummary, t, type DesignDocSummary } from "../designDocToolCard"

const QUOTE_CLASS = "min-w-0 break-words border-l-2 border-brand/50 bg-surface-raised px-3 py-2 text-xs text-text-muted [overflow-wrap:anywhere]"

type CommentOnDesignDoc = {
  summary: DesignDocSummary
  threadId: number | null
  threadState: string | null
  threadKind: "reply" | "new"
  commentId: number | null
  body: string
  selectedMarkdown: string
  startOffset: number | null
  endOffset: number | null
  authorKind: string | null
  version: number | null
  mutationMode: string | null
}

function nestedObject(value: unknown, key: string) {
  return isPlainObject(value) && isPlainObject(value[key]) ? value[key] : null
}

function commentOnDesignDoc(context: ToolCardContext): CommentOnDesignDoc | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed) || !isPlainObject(parsed.design_doc) || !isPlainObject(parsed.comment)) return null
  const summary = parseDesignDocSummary(parsed.design_doc)
  if (!summary) return null
  const thread = isPlainObject(parsed.thread) ? parsed.thread : null
  const anchor = nestedObject(thread, "anchor")
  const version = isPlainObject(parsed.version) ? parsed.version : null
  const comments = thread && Array.isArray(thread.comments) ? thread.comments : []

  return {
    summary,
    threadId: numberValue(thread?.id),
    threadState: displayValue(thread?.state),
    threadKind: comments.length > 1 ? "reply" : "new",
    commentId: numberValue(parsed.comment.id),
    body: typeof parsed.comment.body === "string" ? parsed.comment.body : "",
    selectedMarkdown: displayValue(anchor?.selected_markdown) ?? displayValue(context.input?.selected_markdown) ?? "",
    startOffset: numberValue(anchor?.start_offset) ?? numberValue(context.input?.start_offset),
    endOffset: numberValue(anchor?.end_offset) ?? numberValue(context.input?.end_offset),
    authorKind: displayValue(parsed.comment.author_kind),
    version: numberValue(version?.version_number),
    mutationMode: displayValue(parsed.mutation_mode)
  }
}

function errorMessage(context: ToolCardContext) {
  if (isPlainObject(context.parsedResult)) {
    return displayValue(context.parsedResult.error) ?? displayValue(context.parsedResult.message) ?? displayValue(context.parsedResult.detail)
  }
  return displayValue(context.resultBody)
}

function collapsedSummary(context: ToolCardContext) {
  const result = commentOnDesignDoc(context)
  if (context.resultError && !result) return t("tool_comment_error_summary")
  if (!context.resultBody && context.parsedResult == null) return t("tool_comment_pending_summary")
  return result ? t("tool_commented_on", { doc: result.summary.docRef }) : null
}

function renderExpanded(context: ToolCardContext) {
  const result = commentOnDesignDoc(context)
  if (context.resultError && !result) return <DesignDocErrorCard message={errorMessage(context) ?? t("tool_unknown_error")} title={t("tool_comment_title")} />
  if (!context.resultBody && context.parsedResult == null) return <DesignDocPendingCard title={t("tool_comment_title")} />
  if (!result) return null

  const docId = result.summary.docRef.match(/(\d+)\s*$/)?.[1]
  const href = docId ? `/design_docs/${docId}${result.threadId == null ? "" : `#thread-${result.threadId}`}` : null
  const anchorRange = result.startOffset != null && result.endOffset != null ? `${result.startOffset}–${result.endOffset}` : null

  return (
    <CardShell>
      <div className="flex min-w-0 flex-wrap items-center gap-2">
        <Badge>{t("tool_comment")}</Badge>
        {result.threadState ? <StatePill state={result.threadState} /> : null}
        <Badge>{t(result.threadKind === "reply" ? "tool_reply" : "tool_new_thread")}</Badge>
        {result.summary.state ? <StatePill state={result.summary.state} /> : null}
        {result.summary.visibility ? <Badge>{result.summary.visibility}</Badge> : null}
        {result.authorKind ? <Badge>{result.authorKind.replace(/_/g, " ")}</Badge> : null}
        {result.version != null ? <Badge>{t("tool_version", { number: result.version })}</Badge> : null}
        {result.mutationMode ? <Badge>{result.mutationMode.replace(/_/g, " ")}</Badge> : null}
      </div>
      <div className="min-w-0 text-sm font-medium text-text-primary">
        {href ? (
          <a className="break-all font-mono text-brand hover:underline" href={href}>
            {result.summary.docRef}
          </a>
        ) : (
          result.summary.docRef
        )}
        <span className="font-sans"> — {result.summary.title}</span>
      </div>
      <div className="grid min-w-0 gap-2 sm:grid-cols-2">
        {result.threadId != null ? <Row label={t("tool_thread")} value={String(result.threadId)} /> : null}
        {result.commentId != null ? <Row label={t("tool_comment_id")} value={String(result.commentId)} /> : null}
        {anchorRange ? <Row label={t("tool_anchor")} value={anchorRange} /> : null}
      </div>
      {result.selectedMarkdown ? (
        <blockquote className={QUOTE_CLASS}>
          <MarkdownPreview maxChars={320} maxLines={3} text={result.selectedMarkdown} />
        </blockquote>
      ) : (
        <EmptyState>{t("tool_no_selection")}</EmptyState>
      )}
      <MarkdownPreview linkifyUrls maxChars={720} modalLabel={t("tool_full_comment")} text={result.body} title={t("tool_comment_body")} />
    </CardShell>
  )
}

const commentOnDesignDocToolCard: ToolCardRenderer = { toolName: "comment_on_design_doc", collapsedSummary, renderExpanded }
export default commentOnDesignDocToolCard

export const examples: ToolCardExample[] = [
  {
    id: "anchored_agent_comment",
    label: "Anchored agent comment",
    input: {
      doc_ref: "DOC-20",
      body: "Please see JOB-42 and https://example.test.",
      start_offset: 48,
      end_offset: 76,
      selected_markdown: "## Execution graph"
    },
    parsedResult: {
      design_doc: { doc_ref: "DOC-20", title: "Target Graphs", visibility: "public", state: "draft" },
      thread: { id: 12, state: "open", anchor: { start_offset: 48, end_offset: 76, selected_markdown: "## Execution graph" }, comments: [{ id: 5 }] },
      comment: { id: 5, author_kind: "agent", body: "Please see JOB-42 and https://example.test." },
      version: { version_number: 4 },
      mutation_mode: "comment_only"
    }
  },
  { id: "permission_error", label: "Permission error", resultBody: "Error: not allowed to comment on DOC-20", resultError: true }
]
