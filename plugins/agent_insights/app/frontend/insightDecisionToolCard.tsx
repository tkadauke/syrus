import i18n from "i18next"
import type { ToolCardContext } from "@app/pluginToolCards"
import { isPlainObject } from "@app/toolCardParsing"
import { DescriptionList, Text } from "@app/components/ui"
import { CardShell, displayValue, EmptyState, EntityReference, SectionLabel, StatePill } from "@app/routes/chat/toolCardUi"
import { InsightErrorCard, InsightRefList, TextPreview } from "./agentInsightToolCard"

export type InsightDecision = "accept" | "dismiss"

type DecisionOutcome = {
  insightIds: string[]
  inputInsightIds: string[]
  states: Array<{ id: string; state: string }>
  message: string | null
  reason: string | null
  pendingActionId: string | null
  intendedTransition: string | null
  state: string | null
}

function unwrap(value: unknown): unknown {
  if (!isPlainObject(value)) return value
  if (value.structured_content != null) return unwrap(value.structured_content)
  if (isPlainObject(value.data)) return unwrap(value.data)
  if (Array.isArray(value.content)) {
    const text = value.content.find((item) => isPlainObject(item) && typeof item.text === "string")
    if (isPlainObject(text) && typeof text.text === "string") {
      try {
        return unwrap(JSON.parse(text.text))
      } catch {
        return text.text
      }
    }
  }
  return value
}

function ids(value: unknown): string[] {
  const values = Array.isArray(value) ? value : value == null ? [] : [value]
  return values.flatMap((item) => {
    const id = displayValue(item)
    return id ? [id] : []
  })
}

function inputIds(context: ToolCardContext) {
  const many = ids(context.input?.insight_ids)
  return many.length ? many : ids(context.input?.insight_id)
}

function resultPayload(context: ToolCardContext): Record<string, unknown> | null {
  const parsed = unwrap(context.parsedResult)
  if (isPlainObject(parsed)) return parsed
  if (!context.resultBody.trim()) return null
  try {
    const body = unwrap(JSON.parse(context.resultBody))
    return isPlainObject(body) ? body : null
  } catch {
    return null
  }
}

function errorMessage(context: ToolCardContext) {
  const payload = resultPayload(context)
  return displayValue(payload?.error) ?? displayValue(payload?.message) ?? (context.resultBody.trim() || i18n.t("agent_insights:tool_action_error"))
}

export function parseDecisionOutcome(context: ToolCardContext): DecisionOutcome | null {
  const result = resultPayload(context)
  const requestedIds = inputIds(context)
  if (!result) {
    if (!requestedIds.length && !context.input?.reason) return null
    return {
      insightIds: [],
      inputInsightIds: requestedIds,
      states: [],
      message: null,
      reason: typeof context.input?.reason === "string" ? context.input.reason : null,
      pendingActionId: null,
      intendedTransition: null,
      state: null
    }
  }

  const resultIds = ids(result.insight_ids)
  const states = isPlainObject(result.states)
    ? Object.entries(result.states).flatMap(([id, state]) => {
        const label = displayValue(state)
        return label ? [{ id, state: label }] : []
      })
    : []
  const pendingActionId = displayValue(result.pending_action_id) ?? displayValue(result.pending_confirmation_id)
  const live = pendingActionId && displayValue(context.livePendingAction?.id) === pendingActionId ? context.livePendingAction : null

  return {
    insightIds: resultIds,
    inputInsightIds: requestedIds,
    states,
    message: displayValue(result.message),
    reason: typeof context.input?.reason === "string" ? context.input.reason : null,
    pendingActionId,
    intendedTransition: displayValue(result.intended_transition),
    state: live?.state ?? displayValue(result.state) ?? (pendingActionId ? "pending" : null)
  }
}

function actionLabel(action: InsightDecision) {
  return i18n.t(`agent_insights:tool_${action}_label`)
}

function pastTense(action: InsightDecision) {
  return i18n.t(`agent_insights:tool_${action}_past`)
}

export function decisionSummary(context: ToolCardContext, action: InsightDecision) {
  if (context.resultError) return i18n.t("agent_insights:tool_action_failed", { action: actionLabel(action) })
  const outcome = parseDecisionOutcome(context)
  if (!outcome) return actionLabel(action)
  const allIds = outcome.insightIds.length ? outcome.insightIds : outcome.inputInsightIds
  const count = allIds.length
  const target = count === 1 ? `INSIGHT-${allIds[0]}` : i18n.t("agent_insights:tool_insight_count", { count })
  if (outcome.pendingActionId) {
    const state = outcome.state === "pending" ? i18n.t("agent_insights:tool_pending_confirmation") : outcome.state?.replace(/_/g, " ")
    return `${actionLabel(action)} ${target} · ${state ?? i18n.t("agent_insights:tool_pending_confirmation")}`
  }
  return `${pastTense(action)} ${target}`
}

export function InsightDecisionOutcomeCard({ context, action }: { context: ToolCardContext; action: InsightDecision }) {
  if (context.resultError) return <InsightErrorCard message={errorMessage(context)} />
  const outcome = parseDecisionOutcome(context)
  if (!outcome) return null
  const live = outcome.pendingActionId && displayValue(context.livePendingAction?.id) === outcome.pendingActionId ? context.livePendingAction : null
  const allIds = outcome.insightIds.length ? outcome.insightIds : outcome.inputInsightIds

  return (
    <CardShell>
      <div className="flex min-w-0 flex-wrap items-center gap-2">
        <SectionLabel>{actionLabel(action)}</SectionLabel>
        {outcome.state ? <StatePill state={outcome.state} /> : null}
      </div>
      {outcome.message ? <Text className="break-words">{outcome.message}</Text> : <EmptyState>{i18n.t("agent_insights:tool_empty_result")}</EmptyState>}
      {live?.detail || live?.label ? <Text muted>{live.detail ?? live.label}</Text> : null}
      <DescriptionList.Root className="min-w-0 sm:grid-cols-2" density="compact">
        {outcome.inputInsightIds.length ? (
          <DescriptionList.Item label={i18n.t("agent_insights:tool_requested_insights")}>
            <InsightRefList insightIds={outcome.inputInsightIds} />
          </DescriptionList.Item>
        ) : null}
        {allIds.length ? (
          <DescriptionList.Item label={i18n.t("agent_insights:tool_result_insights")}>
            <InsightRefList insightIds={allIds} />
          </DescriptionList.Item>
        ) : null}
        {outcome.pendingActionId ? (
          <DescriptionList.Item label={i18n.t("agent_insights:tool_pending_action")}>
            <span className="break-all font-mono text-xs">#{outcome.pendingActionId}</span>
          </DescriptionList.Item>
        ) : null}
        {outcome.intendedTransition ? (
          <DescriptionList.Item label={i18n.t("agent_insights:tool_intended_transition")}>
            <span className="break-words">{outcome.intendedTransition.replace(/_/g, " ")}</span>
          </DescriptionList.Item>
        ) : null}
      </DescriptionList.Root>
      {outcome.states.length ? (
        <div>
          <SectionLabel>{i18n.t("agent_insights:tool_result_states")}</SectionLabel>
          <div className="flex min-w-0 flex-wrap gap-2">
            {outcome.states.map(({ id, state }) => (
              <span className="inline-flex min-w-0 flex-wrap items-center gap-1" key={id}>
                <EntityReference id={id} kind="insight" wrap="nowrap" />
                <StatePill state={state} />
              </span>
            ))}
          </div>
        </div>
      ) : null}
      {outcome.reason != null ? (
        <div>
          <SectionLabel>{i18n.t("agent_insights:tool_reason")}</SectionLabel>
          <TextPreview emptyState={<EmptyState>{i18n.t("agent_insights:tool_empty_reason")}</EmptyState>} maxChars={320} text={outcome.reason} />
        </div>
      ) : null}
    </CardShell>
  )
}
