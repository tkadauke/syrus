import i18n from "@app/i18n"
import { isPlainObject, type ToolCardContext, type ToolCardExample, type ToolCardPriorCall, type ToolCardRenderer } from "@app/pluginToolCards"
import { intlLocale, formatRelativeDate } from "../../../lib/relativeTime"
import { MarkdownPreview } from "../toolCardMarkdown"
import { CardShell, displayValue, EmptyState, EntityReference, Row, StatePill } from "../toolCardUi"

type WakeupDetails = { wakeupId: string; fireAt: string | null; prompt: string }
type CancelWakeupCard = (WakeupDetails & { state: "cancelled" }) | { state: "error"; error: string } | { state: "pending" } | { state: "empty" }

function contentError(value: unknown) {
  if (!isPlainObject(value) || !Array.isArray(value.content)) return null
  const block = value.content.find((item) => isPlainObject(item) && item.type === "text")
  return isPlainObject(block) ? displayValue(block.text) : null
}

function errorMessage(context: ToolCardContext) {
  if (!context.resultError) return null
  const parsed = context.parsedResult
  if (isPlainObject(parsed)) {
    for (const key of ["error", "message", "detail", "reason"]) {
      const value = displayValue(parsed[key])
      if (value) return value
    }
    const content = contentError(parsed)
    if (content) return content
  }
  return displayValue(context.resultBody) ?? i18n.t("chat:tool_card_cancel_wakeup_failed")
}

function detailsFromPriorCall(call: ToolCardPriorCall, wakeupId: string): Partial<WakeupDetails> | null {
  if (call.toolName === "schedule_wakeup" && isPlainObject(call.parsedResult) && displayValue(call.parsedResult.wakeup_id) === wakeupId) {
    return { fireAt: displayValue(call.parsedResult.fire_at) ?? displayValue(call.input.fire_at), prompt: displayValue(call.input.prompt) ?? "" }
  }
  if (call.toolName !== "list_wakeups" || !isPlainObject(call.parsedResult) || !Array.isArray(call.parsedResult.wakeups)) return null
  const row = call.parsedResult.wakeups.find((item) => isPlainObject(item) && displayValue(item.id) === wakeupId)
  if (!isPlainObject(row)) return null
  return { fireAt: displayValue(row.fire_at), prompt: displayValue(row.prompt) ?? displayValue(row.prompt_preview) ?? "" }
}

function parseCancelWakeup(context: ToolCardContext): CancelWakeupCard {
  const error = errorMessage(context)
  if (error) return { state: "error", error }
  if (context.resultSettled === false) return { state: "pending" }
  const parsed = context.parsedResult
  if (!isPlainObject(parsed) || parsed.cancelled !== true) return { state: "empty" }
  const wakeupId = displayValue(parsed.wakeup_id)
  if (!wakeupId) return { state: "empty" }
  const prior = context.priorCalls?.map((call) => detailsFromPriorCall(call, wakeupId)).find(Boolean)
  return {
    state: "cancelled",
    wakeupId,
    fireAt: displayValue(parsed.fire_at) ?? prior?.fireAt ?? null,
    prompt: displayValue(parsed.prompt) ?? prior?.prompt ?? ""
  }
}

function validDate(value: string | null) {
  if (!value) return null
  const date = new Date(value)
  return Number.isNaN(date.getTime()) ? null : date
}

function collapsedSummary(context: ToolCardContext) {
  const result = parseCancelWakeup(context)
  if (result.state === "error") return i18n.t("chat:tool_card_cancel_wakeup_failed_with_error", { error: result.error })
  if (result.state === "pending") return i18n.t("chat:tool_card_cancel_wakeup_pending")
  if (result.state === "empty") return null
  return i18n.t("chat:tool_card_wakeup_cancelled", { id: result.wakeupId })
}

function renderExpanded(context: ToolCardContext) {
  const result = parseCancelWakeup(context)
  if (result.state === "empty") return <EmptyState>{i18n.t("chat:tool_card_cancel_wakeup_empty")}</EmptyState>
  if (result.state === "error") {
    return (
      <CardShell tone="danger">
        <StatePill state="failed" />
        <div className="min-w-0 break-words text-danger-text [overflow-wrap:anywhere]">{result.error}</div>
      </CardShell>
    )
  }
  if (result.state === "pending") {
    return (
      <CardShell tone="info">
        <StatePill state="pending" />
        <div className="break-words text-text-muted">{i18n.t("chat:tool_card_cancel_wakeup_pending")}</div>
      </CardShell>
    )
  }

  const fireDate = validDate(result.fireAt)
  return (
    <CardShell tone="success">
      <div className="flex min-w-0 flex-wrap items-center gap-2">
        <StatePill state="cancelled" />
        <EntityReference chatId={context.chatSessionId} id={result.wakeupId} kind="wakeup" wrap="break" />
      </div>
      {result.fireAt ? (
        <Row
          label={i18n.t("chat:tool_card_fires_at")}
          value={
            fireDate ? (
              <span className="flex min-w-0 flex-wrap gap-x-2 gap-y-1">
                <time dateTime={result.fireAt}>{new Intl.DateTimeFormat(intlLocale(), { dateStyle: "medium", timeStyle: "short" }).format(fireDate)}</time>
                <span className="text-text-muted">({formatRelativeDate(fireDate)})</span>
                <span className="break-all font-mono text-text-muted">{fireDate.toISOString()} UTC</span>
              </span>
            ) : (
              result.fireAt
            )
          }
        />
      ) : null}
      {result.prompt ? (
        <MarkdownPreview linkifySlugs linkifyUrls maxChars={640} text={result.prompt} title={i18n.t("chat:tool_card_cancel_wakeup_prompt")} />
      ) : null}
    </CardShell>
  )
}

const cancelWakeupToolCard: ToolCardRenderer = {
  toolName: "cancel_wakeup",
  renderWhilePending: true,
  collapsedSummary,
  renderExpanded,
  renderPending: renderExpanded
}

export default cancelWakeupToolCard

export const examples: ToolCardExample[] = [
  {
    id: "cancelled",
    label: "Cancelled wakeup with context",
    description: "Linked wakeup reference, original fire time, prompt, and responsive wrapping.",
    sourceType: "claude",
    parsedResult: {
      cancelled: true,
      wakeup_id: 17,
      fire_at: "2026-12-01T15:30:00Z",
      prompt: "Review **JOB-42** and https://example.test/status before reporting back."
    }
  },
  { id: "not_pending", label: "Wakeup not found or pending", sourceType: "codex", resultBody: "wakeup not found or not pending", resultError: true },
  { id: "pending", label: "Cancellation pending", resultSettled: false },
  { id: "empty", label: "Empty response", parsedResult: {} }
]
