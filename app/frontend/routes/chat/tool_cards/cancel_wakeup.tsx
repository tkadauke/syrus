import { isPlainObject, type ToolCardContext, type ToolCardExample, type ToolCardRenderer } from "@app/pluginToolCards"
import { ErrorCard } from "../chatHelperToolCard"
import { CardShell, displayValue, EntityReference, Row, StatePill } from "../toolCardUi"

type CancelWakeupResult = { wakeupId: string; prompt: string | null; fireAt: string | null }

function errorMessage(context: ToolCardContext) {
  if (!context.resultError) return null
  return displayValue(context.resultBody) ?? "Wakeup could not be cancelled."
}

function parseCancelWakeup(context: ToolCardContext): CancelWakeupResult | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed)) return null
  const wakeupId = displayValue(parsed.wakeup_id)
  if (!wakeupId || parsed.cancelled !== true) return null
  return {
    wakeupId,
    prompt: displayValue(parsed.prompt),
    fireAt: displayValue(parsed.fire_at)
  }
}

function collapsedSummary(context: ToolCardContext) {
  if (errorMessage(context)) return "Wakeup not cancelled"
  const result = parseCancelWakeup(context)
  if (!result) return null
  return `Cancelled wakeup #${result.wakeupId}`
}

function renderExpanded(context: ToolCardContext) {
  const error = errorMessage(context)
  if (error) return <ErrorCard title="Wakeup not cancelled" message={error} />

  const result = parseCancelWakeup(context)
  if (!result) return null

  return (
    <CardShell>
      <div className="flex min-w-0 flex-wrap items-center gap-2">
        <span className="text-gray-700 dark:text-gray-300">Cancelled wakeup</span>
        <EntityReference id={result.wakeupId} kind="wakeup" />
        <StatePill state="cancelled" />
      </div>
      {result.fireAt || result.prompt ? (
        <dl className="mt-2 grid min-w-0 gap-1 sm:grid-cols-2">
          {result.fireAt ? <Row label="Was scheduled for" value={result.fireAt} /> : null}
          {result.prompt ? (
            <div className="min-w-0 sm:col-span-2">
              <dt className="text-2xs font-semibold uppercase text-text-muted">Prompt</dt>
              <dd className="whitespace-pre-wrap break-words text-text-secondary">{result.prompt}</dd>
            </div>
          ) : null}
        </dl>
      ) : null}
    </CardShell>
  )
}

export const examples: ToolCardExample[] = [
  {
    id: "cancelled_with_context",
    label: "Cancelled wakeup with context",
    parsedResult: {
      cancelled: true,
      wakeup_id: 42,
      prompt: "Check whether the deployment completed and report the result.",
      fire_at: "2026-10-20T09:30:00Z"
    }
  },
  {
    id: "not_pending",
    label: "Wakeup not found or no longer pending",
    resultBody: "Error: wakeup not found or not pending",
    resultError: true
  },
  {
    id: "legacy_minimal_success",
    label: "Cancelled wakeup without optional context",
    parsedResult: { cancelled: true, wakeup_id: 42 }
  }
]

const cancelWakeupToolCard: ToolCardRenderer = {
  toolName: "cancel_wakeup",
  collapsedSummary,
  renderExpanded
}

export default cancelWakeupToolCard
