import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import { isPlainObject, normalizedToolCardParsedResult } from "@app/toolCardParsing"
import { TextPreview } from "@app/routes/chat/toolCardMarkdown"
import { CardShell, CopyableValue, displayValue, Row, SectionLabel, StatePill } from "@app/routes/chat/toolCardUi"

function parseResult(context: ToolCardContext) {
  const value = normalizedToolCardParsedResult(context.parsedResult)
  if (!isPlainObject(value)) return null
  const pendingActionId = displayValue(value.pending_action_id) || displayValue(value.pending_confirmation_id)
  const state = displayValue(value.state)
  const threadId = displayValue(value.thread_id)
  const statement = displayValue(value.statement)
  if (!pendingActionId || !state || !threadId || !statement) return null
  const live = context.livePendingAction
  return {
    pendingActionId,
    state: live && displayValue(live.id) === pendingActionId ? live.state : state,
    message: displayValue(value.message),
    threadId,
    statement,
    user: displayValue(value.user),
    host: displayValue(value.host),
    database: displayValue(value.database),
    timeSeconds: displayValue(value.time_seconds),
    queryState: displayValue(value.query_state)
  }
}

function errorMessage(context: ToolCardContext) {
  const value = normalizedToolCardParsedResult(context.parsedResult)
  if (isPlainObject(value)) return displayValue(value.error) || displayValue(value.message) || context.resultBody
  return context.resultBody || "The query interruption request failed without an error message."
}

function collapsedSummary(context: ToolCardContext) {
  const result = parseResult(context)
  if (result) return result.message || `Kill MySQL query on thread ${result.threadId}`
  return context.resultError ? "MySQL query interruption failed" : null
}

function renderExpanded(context: ToolCardContext) {
  const result = parseResult(context)
  if (!result) {
    if (!context.resultError) return null
    const inputThreadId = displayValue(context.input?.thread_id)
    return (
      <CardShell>
        <StatePill state="failed" />
        <div className="font-semibold text-text-primary">MySQL query interruption failed</div>
        {inputThreadId ? (
          <div>
            <SectionLabel>Thread</SectionLabel>
            <CopyableValue value={inputThreadId} />
          </div>
        ) : null}
        <TextPreview maxLines={4} modalLabel="Full MySQL error" text={errorMessage(context)} title="Error" />
      </CardShell>
    )
  }

  return (
    <CardShell>
      <div className="flex min-w-0 flex-wrap items-center gap-2">
        <StatePill state={result.state} />
        <span className="font-mono font-semibold text-text-primary">Pending action #{result.pendingActionId}</span>
      </div>
      <div className="grid min-w-0 gap-2 sm:grid-cols-2">
        <div>
          <SectionLabel>MySQL thread</SectionLabel>
          <CopyableValue value={result.threadId} />
        </div>
        {result.queryState ? <Row label="Query state" value={result.queryState} /> : null}
        {result.user ? <Row label="User" value={result.user} /> : null}
        {result.host ? <Row label="Host" value={result.host} /> : null}
        {result.database ? <Row label="Database" value={result.database} /> : null}
        {result.timeSeconds ? <Row label="Running" value={`${result.timeSeconds}s`} /> : null}
      </div>
      <TextPreview lang="sql" maxLines={4} modalLabel="Full redacted statement" text={result.statement} title="Redacted statement" />
      {result.message ? <div className="break-words text-xs text-text-muted">{result.message}</div> : null}
    </CardShell>
  )
}

export const examples: ToolCardExample[] = [
  {
    id: "pending_query",
    label: "Pending query interruption",
    input: { thread_id: 90 },
    parsedResult: {
      pending_confirmation_id: 90,
      pending_action_id: 90,
      state: "pending",
      message: "Kill the query on MySQL thread 90?",
      thread_id: 90,
      statement: "SELECT * FROM users WHERE token = ?",
      user: "syrus",
      host: "worker:3306",
      database: "syrus_production",
      time_seconds: 12,
      query_state: "executing"
    }
  }
]

const adminMysqlKillQueryToolCard: ToolCardRenderer = {
  toolName: "admin_mysql_kill_query",
  argumentSummary: () => "",
  collapsedSummary,
  renderExpanded
}

export default adminMysqlKillQueryToolCard
