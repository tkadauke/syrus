import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { Badge, CardShell, displayValue, StatePill } from "@app/routes/chat/toolCardUi"
import { DesignDocHeader, parseDesignDocSummary, t, type DesignDocSummary } from "../designDocToolCard"

// Plugin-owned tool card for comment_on_design_doc (the pending-action tool-card work).
type CommentOnDesignDoc = {
  summary: DesignDocSummary
  threadState: string | null
  commentBody: string | null
}

function commentOnDesignDoc(context: ToolCardContext): CommentOnDesignDoc | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed) || !isPlainObject(parsed.design_doc) || !isPlainObject(parsed.comment)) return null

  const summary = parseDesignDocSummary(parsed.design_doc)
  if (!summary) return null

  return {
    summary,
    threadState: isPlainObject(parsed.thread) ? displayValue(parsed.thread.state) : null,
    commentBody: displayValue(parsed.comment.body)
  }
}

function collapsedSummary(context: ToolCardContext) {
  const result = commentOnDesignDoc(context)
  if (!result) return null

  return t("tool_commented_on", { doc: result.summary.docRef })
}

function renderExpanded(context: ToolCardContext) {
  const result = commentOnDesignDoc(context)
  if (!result) return null

  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <Badge>{t("tool_comment")}</Badge>
        {result.threadState ? <StatePill state={result.threadState} /> : null}
      </div>
      <DesignDocHeader doc={result.summary} />
      <div className="text-sm font-medium text-gray-900 dark:text-gray-100">{result.summary.title}</div>
      {result.commentBody ? <div className="text-gray-700 dark:text-gray-300">{result.commentBody}</div> : null}
    </CardShell>
  )
}

const commentOnDesignDocToolCard: ToolCardRenderer = {
  toolName: "comment_on_design_doc",
  collapsedSummary,
  renderExpanded
}

export default commentOnDesignDocToolCard
