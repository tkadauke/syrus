import i18n from "i18next"
import type { ReactNode } from "react"
import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import { isPlainObject } from "@app/pluginToolCards"
import { Badge, CardShell, displayValue, EmptyState, EntityReference, SectionLabel, StatePill } from "@app/routes/chat/toolCardUi"
import { MarkdownPreview } from "@app/routes/chat/toolCardMarkdown"
import { InsightErrorCard } from "../agentInsightToolCard"

type Result = {
  insightIds: string[]
  inputIds: string[]
  states: Array<[string, string]>
  proposalTypes: Array<[string, string]>
  jobIds: string[]
  memoryIds: string[]
  pendingId: string | null
  transition: string | null
  state: string | null
  message: string
}

const t = (key: string, options?: Record<string, unknown>) => i18n.t(`agent_insights:${key}`, options)

function list(value: unknown): string[] {
  return Array.isArray(value) ? value.map(displayValue).filter((item): item is string => Boolean(item)) : []
}

function entries(value: unknown): Array<[string, string]> {
  if (!isPlainObject(value)) return []
  return Object.entries(value).flatMap(([id, item]) => {
    const text = displayValue(item)
    return text ? [[id, text]] : []
  })
}

function unwrap(value: unknown): unknown {
  let current = value
  if (isPlainObject(current) && current.structured_content != null) current = current.structured_content
  if (isPlainObject(current) && Array.isArray(current.content)) {
    const block = current.content.find((item) => isPlainObject(item) && typeof item.text === "string")
    if (isPlainObject(block) && typeof block.text === "string") {
      try {
        current = JSON.parse(block.text)
      } catch {
        return current
      }
    }
  }
  return isPlainObject(current) && isPlainObject(current.data) ? current.data : current
}

function parse(context: ToolCardContext): Result | null {
  const value = unwrap(context.parsedResult)
  if (!isPlainObject(value)) return null
  if (!["message", "insight_ids", "states", "proposal_types", "job_ids", "memory_ids", "pending_action_id", "intended_transition"].some((key) => key in value))
    return null
  const inputList = list(context.input?.insight_ids)
  const inputId = displayValue(context.input?.insight_id)
  const pendingId = displayValue(value.pending_action_id) ?? displayValue(value.pending_confirmation_id)
  const live = pendingId && displayValue(context.livePendingAction?.id) === pendingId ? context.livePendingAction : null
  return {
    insightIds: list(value.insight_ids),
    inputIds: inputId ? [inputId, ...inputList.filter((id) => id !== inputId)] : inputList,
    states: entries(value.states),
    proposalTypes: entries(value.proposal_types),
    jobIds: list(value.job_ids),
    memoryIds: list(value.memory_ids),
    pendingId,
    transition: displayValue(value.intended_transition),
    state: live?.state ?? displayValue(value.state) ?? (pendingId ? "pending" : null),
    message: displayValue(value.message) ?? ""
  }
}

function summary(context: ToolCardContext) {
  if (context.resultError) return t("tool_accept_failed")
  const result = parse(context)
  if (!result) return null
  const count = result.insightIds.length || result.inputIds.length
  if (result.pendingId) return t("tool_accept_requested", { count, state: result.state ?? "pending" })
  return count ? t(count === 1 ? "tool_accept_summary" : "tool_accept_summary_plural", { count }) : t("tool_accept_summary_empty")
}

function Refs({ ids, kind }: { ids: string[]; kind: "insight" | "job" | "memory" }) {
  return (
    <div className="flex min-w-0 flex-wrap gap-2">
      {ids.map((id) => (
        <EntityReference href={kind === "memory" ? "/memories" : undefined} id={id} key={id} kind={kind} wrap="nowrap" />
      ))}
    </div>
  )
}

function Values({ values }: { values: Array<[string, string]> }) {
  return (
    <div className="flex min-w-0 flex-wrap gap-1">
      {values.map(([id, value]) => (
        <Badge key={`${id}-${value}`}>
          INSIGHT-{id}: {value.replace(/_/g, " ")}
        </Badge>
      ))}
    </div>
  )
}

function Field({ label, children }: { label: string; children: ReactNode }) {
  return (
    <section className="min-w-0">
      <SectionLabel>{label}</SectionLabel>
      {children}
    </section>
  )
}

function Expanded({ result }: { result: Result }) {
  const hasDetails =
    result.insightIds.length ||
    result.inputIds.length ||
    result.states.length ||
    result.proposalTypes.length ||
    result.jobIds.length ||
    result.memoryIds.length ||
    result.pendingId ||
    result.transition

  return (
    <CardShell>
      <div className="flex min-w-0 flex-wrap items-center gap-2">
        <SectionLabel>{t("tool_accept_label")}</SectionLabel>
        {result.state ? <StatePill state={result.state} /> : null}
        {result.pendingId ? <Badge>#{result.pendingId}</Badge> : null}
      </div>
      <MarkdownPreview
        emptyState={<EmptyState>{t("tool_accept_empty_message")}</EmptyState>}
        linkifySlugs
        linkifyUrls
        maxChars={480}
        maxLines={4}
        modalLabel={t("tool_accept_message")}
        text={result.message}
      />
      {result.inputIds.length ? (
        <Field label={t("tool_accept_input")}>
          <Refs ids={result.inputIds} kind="insight" />
        </Field>
      ) : null}
      {result.insightIds.length ? (
        <Field label={t("tool_accept_insights")}>
          <Refs ids={result.insightIds} kind="insight" />
        </Field>
      ) : null}
      {result.states.length ? (
        <Field label={t("tool_accept_states")}>
          <Values values={result.states} />
        </Field>
      ) : null}
      {result.proposalTypes.length ? (
        <Field label={t("tool_accept_proposals")}>
          <Values values={result.proposalTypes} />
        </Field>
      ) : null}
      {result.jobIds.length ? (
        <Field label={t("tool_accept_jobs")}>
          <Refs ids={result.jobIds} kind="job" />
        </Field>
      ) : null}
      {result.memoryIds.length ? (
        <Field label={t("tool_accept_memories")}>
          <Refs ids={result.memoryIds} kind="memory" />
        </Field>
      ) : null}
      {result.transition ? (
        <Field label={t("tool_accept_transition")}>
          <Badge>{result.transition.replace(/_/g, " ")}</Badge>
        </Field>
      ) : null}
      {!hasDetails ? <EmptyState>{t("tool_accept_empty")}</EmptyState> : null}
    </CardShell>
  )
}

function renderExpanded(context: ToolCardContext) {
  if (context.resultError) return <InsightErrorCard message={context.resultBody.trim() || t("tool_accept_error")} />
  const result = parse(context)
  return result ? <Expanded result={result} /> : null
}

const card: ToolCardRenderer = {
  toolName: "accept_insight",
  collapsedSummary: summary,
  renderExpanded
}
export default card

export const examples: ToolCardExample[] = [
  {
    id: "accepted_with_outputs",
    label: "Accepted with created records",
    input: { insight_id: 41 },
    parsedResult: {
      message: "Accepted **INSIGHT-41**.",
      insight_ids: [41],
      states: { 41: "accepted" },
      proposal_types: { 41: "create_job" },
      job_ids: [7761],
      memory_ids: [162]
    }
  },
  {
    id: "bulk_pending",
    label: "Bulk acceptance pending",
    input: { insight_ids: [41, 42] },
    parsedResult: {
      pending_action_id: 92,
      message: "Accept INSIGHT-41 and INSIGHT-42?",
      insight_ids: [41, 42],
      proposal_types: { 41: "create_job", 42: "save_memory" },
      intended_transition: "accept_insights"
    }
  },
  { id: "error", label: "Acceptance failed", resultBody: "Insights are no longer pending.", resultError: true }
]
