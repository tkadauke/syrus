import i18n from "i18next"
import { useT } from "@app/hooks/useT"
import { isPlainObject, type ToolCardContext, type ToolCardExample, type ToolCardRenderer } from "@app/pluginToolCards"
import { Badge, CardShell, displayValue, EmptyState, EntityReference, SectionLabel, StatePill } from "@app/routes/chat/toolCardUi"
import { InsightErrorCard, TextPreview } from "../agentInsightToolCard"

type Reference = { retiredId: string; supersedingId: string }
type RetireOutcome = {
  insightIds: string[]
  message: string | null
  reason: string | null
  retireAccepted: boolean
  state: string | null
  states: Array<{ id: string; state: string }>
  supersedingInsights: Reference[]
  supersedingJobs: Reference[]
  jobIds: string[]
  memoryIds: string[]
}

function values(value: unknown): string[] {
  if (!Array.isArray(value)) return []
  return value.flatMap((entry) => {
    const parsed = displayValue(entry)
    return parsed ? [parsed] : []
  })
}

function entries(value: unknown): Array<[string, string]> {
  if (!isPlainObject(value)) return []
  return Object.entries(value).flatMap(([key, entry]) => {
    const parsedKey = displayValue(key)
    const parsedValue = displayValue(entry)
    return parsedKey && parsedValue ? [[parsedKey, parsedValue]] : []
  })
}

function unwrap(value: unknown): unknown {
  let current = value
  for (let depth = 0; depth < 4; depth += 1) {
    if (!isPlainObject(current)) return current
    if (current.structured_content != null) {
      current = current.structured_content
      continue
    }
    if (isPlainObject(current.data)) {
      current = current.data
      continue
    }
    if (Array.isArray(current.content)) {
      const text = current.content.find((item) => isPlainObject(item) && typeof item.text === "string")
      if (isPlainObject(text)) {
        try {
          current = JSON.parse(text.text as string)
          continue
        } catch {
          return current
        }
      }
    }
    return current
  }
  return current
}

export function parseRetireOutcome(context: ToolCardContext): RetireOutcome | null {
  const result = unwrap(context.parsedResult)
  const input = context.input ?? {}
  const parsed = isPlainObject(result) ? result : {}
  const resultIds = values(parsed.insight_ids)
  const inputIds = values(input.insight_ids)
  const singularId = displayValue(input.target_insight_id)
  const legacyId = context.resultBody.match(/Suggestion #(\d+)/)?.[1] ?? null
  const insightIds = resultIds.length ? resultIds : inputIds.length ? inputIds : singularId ? [singularId] : legacyId ? [legacyId] : []
  const live = context.livePendingAction
  const resultState = displayValue(parsed.state)
  const message =
    displayValue(parsed.message) ??
    (!isPlainObject(result)
      ? displayValue(context.resultBody.trim())
      : Object.keys(parsed).length > 0 && (resultIds.length > 0 || resultState)
        ? i18n.t("agent_insights:tool_outcome_fallback")
        : null)
  const reason = typeof input.reason === "string" ? input.reason : null
  const singularInsight = displayValue(input.superseded_by_insight_id)
  const singularJob = displayValue(input.superseded_by_job_id)
  const supersedingInsights = entries(input.superseded_by_insight_ids).map(([retiredId, supersedingId]) => ({ retiredId, supersedingId }))
  const supersedingJobs = entries(input.superseded_by_job_ids).map(([retiredId, supersedingId]) => ({ retiredId, supersedingId }))
  if (singularId && singularInsight) supersedingInsights.unshift({ retiredId: singularId, supersedingId: singularInsight })
  if (singularId && singularJob) supersedingJobs.unshift({ retiredId: singularId, supersedingId: singularJob })

  const states = entries(parsed.states).map(([id, state]) => ({ id, state }))
  const hasContent = insightIds.length > 0 || message || reason || states.length > 0 || live || resultState || Object.keys(parsed).length === 0
  if (!hasContent) return null

  return {
    insightIds,
    message,
    reason,
    retireAccepted: input.retire_accepted === true,
    state: live?.state ?? resultState,
    states,
    supersedingInsights,
    supersedingJobs,
    jobIds: values(parsed.job_ids),
    memoryIds: values(parsed.memory_ids)
  }
}

function InsightLinks({ ids }: { ids: string[] }) {
  return (
    <div className="flex min-w-0 flex-wrap gap-2">
      {ids.map((id) => (
        <EntityReference id={id} key={id} kind="insight" wrap="nowrap" />
      ))}
    </div>
  )
}

function ReferenceRows({ references, kind }: { references: Reference[]; kind: "insight" | "job" }) {
  if (references.length === 0) return null
  return (
    <div className="space-y-1">
      {references.map(({ retiredId, supersedingId }) => (
        <div className="flex min-w-0 flex-wrap items-center gap-2" key={`${retiredId}-${kind}-${supersedingId}`}>
          <EntityReference id={retiredId} kind="insight" wrap="nowrap" />
          <span aria-hidden="true" className="text-text-muted">
            →
          </span>
          <EntityReference id={supersedingId} kind={kind} wrap="nowrap" />
        </div>
      ))}
    </div>
  )
}

function RetireCard({ context, outcome }: { context: ToolCardContext; outcome: RetireOutcome }) {
  const { t } = useT("agent_insights")
  const live = context.livePendingAction
  const empty = outcome.insightIds.length === 0 && !outcome.message && !outcome.reason && !outcome.state

  return (
    <CardShell>
      <div className="flex min-w-0 flex-wrap items-center gap-2">
        <SectionLabel>{t("tool_retire_label")}</SectionLabel>
        {outcome.state ? <StatePill state={outcome.state} /> : null}
        {outcome.retireAccepted ? <Badge>{t("tool_retire_accepted")}</Badge> : null}
      </div>
      {outcome.message ? <div className="break-words text-text-secondary">{outcome.message}</div> : null}
      {live?.detail || live?.label ? <div className="break-words text-text-muted">{live.detail ?? live.label}</div> : null}
      {empty ? <EmptyState>{t("tool_retire_empty")}</EmptyState> : null}
      {outcome.insightIds.length > 0 ? (
        <div>
          <SectionLabel>{t("tool_retired_insights")}</SectionLabel>
          <InsightLinks ids={outcome.insightIds} />
        </div>
      ) : null}
      {outcome.states.length > 0 ? (
        <div>
          <SectionLabel>{t("tool_result_states")}</SectionLabel>
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
      {outcome.supersedingInsights.length > 0 ? (
        <div>
          <SectionLabel>{t("tool_superseding_insights")}</SectionLabel>
          <ReferenceRows kind="insight" references={outcome.supersedingInsights} />
        </div>
      ) : null}
      {outcome.supersedingJobs.length > 0 ? (
        <div>
          <SectionLabel>{t("tool_superseding_jobs")}</SectionLabel>
          <ReferenceRows kind="job" references={outcome.supersedingJobs} />
        </div>
      ) : null}
      {outcome.jobIds.length > 0 ? (
        <div>
          <SectionLabel>{t("tool_result_jobs")}</SectionLabel>
          <div className="flex min-w-0 flex-wrap gap-2">
            {outcome.jobIds.map((id) => (
              <EntityReference id={id} key={id} kind="job" wrap="nowrap" />
            ))}
          </div>
        </div>
      ) : null}
      {outcome.memoryIds.length > 0 ? (
        <div>
          <SectionLabel>{t("tool_result_memories")}</SectionLabel>
          <div className="flex min-w-0 flex-wrap gap-2">
            {outcome.memoryIds.map((id) => (
              <EntityReference id={id} key={id} kind="memory" wrap="nowrap" />
            ))}
          </div>
        </div>
      ) : null}
      <div>
        <SectionLabel>{t("tool_reason")}</SectionLabel>
        <TextPreview emptyState={<EmptyState>{t("tool_reason_empty")}</EmptyState>} maxChars={420} text={outcome.reason ?? ""} />
      </div>
    </CardShell>
  )
}

function collapsedSummary(context: ToolCardContext) {
  if (context.resultError) return i18n.t("agent_insights:tool_retire_failed")
  const outcome = parseRetireOutcome(context)
  if (!outcome) return null
  if (outcome.insightIds.length > 1) return i18n.t("agent_insights:tool_retire_summary_bulk", { count: outcome.insightIds.length })
  return outcome.insightIds[0]
    ? i18n.t("agent_insights:tool_retire_summary_with_id", { id: outcome.insightIds[0] })
    : i18n.t("agent_insights:tool_retire_summary")
}

function renderExpanded(context: ToolCardContext) {
  if (context.resultError) return <InsightErrorCard message={context.resultBody.trim() || i18n.t("agent_insights:tool_retire_error")} />
  const outcome = parseRetireOutcome(context)
  return outcome ? <RetireCard context={context} outcome={outcome} /> : null
}

const retireInsightToolCard: ToolCardRenderer = {
  toolName: "retire_insight",
  collapsedSummary,
  renderExpanded
}

export default retireInsightToolCard

export const examples: ToolCardExample[] = [
  {
    id: "bulk_pending",
    label: "Bulk retirement pending confirmation",
    input: {
      insight_ids: [41, 42],
      reason: "Duplicates of **newer findings** in JOB-82. See https://example.test/audit.",
      retire_accepted: true,
      superseded_by_insight_ids: { 41: 44 },
      superseded_by_job_ids: { 42: 82 }
    },
    parsedResult: { state: "pending", message: "Retire insights #41, #42?", insight_ids: [41, 42] }
  },
  {
    id: "completed_provider_envelope",
    label: "Completed retirement in a provider envelope",
    sourceType: "codex",
    parsedResult: {
      content: [
        {
          type: "text",
          text: JSON.stringify({
            message: "Retired 2 insights.",
            insight_ids: [41, 42],
            states: { 41: "retired", 42: "retired" },
            job_ids: [82],
            memory_ids: [9]
          })
        }
      ]
    }
  },
  { id: "error", label: "Retirement error", resultBody: "Insight #41 is already retired.", resultError: true },
  { id: "empty", label: "Empty result", resultBody: "" }
]
