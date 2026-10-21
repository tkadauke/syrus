import i18n from "i18next"
import { isPlainObject, type ToolCardContext, type ToolCardExample, type ToolCardRenderer } from "@app/pluginToolCards"
import { Badge, CardShell, displayValue, EmptyState, EntityReference, SectionLabel, StatePill } from "@app/routes/chat/toolCardUi"
import { MarkdownPreview } from "@app/routes/chat/toolCardMarkdown"
import { InsightErrorCard, parseOutcome } from "../agentInsightToolCard"

const MARKDOWN_FIELDS = new Set(["summary", "suggested_prompt", "memory_suggestion", "stale_memory_text", "stale_memory_evidence"])
const FIELD_ORDER = [
  "title",
  "summary",
  "category",
  "severity",
  "confidence",
  "proposal_type",
  "evidence",
  "suggested_prompt",
  "memory_suggestion",
  "target_memory_id",
  "stale_memory_text",
  "stale_memory_evidence"
] as const

function t(key: string, options?: Record<string, unknown>) {
  return i18n.t(`agent_insights:${key}`, options)
}

function labelFor(field: string) {
  return t(`tool_update_field_${field}`)
}

function resultMessage(context: ToolCardContext): string | null {
  const read = (value: unknown): string | null => {
    if (typeof value === "string") return value.trim() || null
    if (!isPlainObject(value)) return null
    if (typeof value.message === "string") return value.message.trim() || null
    if (value.structured_content != null) return read(value.structured_content)
    if (isPlainObject(value.data)) return read(value.data)
    if (Array.isArray(value.content)) {
      for (const block of value.content) {
        if (!isPlainObject(block) || typeof block.text !== "string" || !block.text.trim()) continue
        try {
          return read(JSON.parse(block.text)) ?? block.text.trim()
        } catch {
          return block.text.trim()
        }
      }
    }
    return null
  }

  return read(context.parsedResult) ?? (context.resultBody.trim() || null)
}

function insightId(context: ToolCardContext) {
  return displayValue(context.input?.target_insight_id) ?? parseOutcome(context)?.targetInsightId ?? null
}

function EvidenceValue({ value }: { value: unknown }) {
  if (!Array.isArray(value) || value.length === 0) return <EmptyState>{t("tool_update_empty")}</EmptyState>
  return (
    <div className="flex min-w-0 flex-wrap gap-2">
      {value.map((item, index) => {
        if (!isPlainObject(item)) return <Badge key={index}>{String(item)}</Badge>
        const jobId = displayValue(item.job_id)
        const runId = displayValue(item.run_id)
        const kind = displayValue(item.kind)
        return (
          <span className="flex min-w-0 flex-wrap items-center gap-1" key={`${jobId}-${runId}-${kind}-${index}`}>
            {kind ? <Badge>{kind.replace(/_/g, " ")}</Badge> : null}
            {jobId ? <EntityReference href={`/jobs/${jobId}`} id={jobId} kind="job" wrap="nowrap" /> : null}
            {runId ? <EntityReference href={`/admin/runs/${runId}/transcript`} id={runId} kind="run" wrap="nowrap" /> : null}
          </span>
        )
      })}
    </div>
  )
}

function FieldValue({ field, value }: { field: string; value: unknown }) {
  if (field === "evidence") return <EvidenceValue value={value} />
  if (field === "target_memory_id") {
    const id = displayValue(value)
    return id ? <EntityReference id={id} kind="memory" wrap="nowrap" /> : <EmptyState>{t("tool_update_empty")}</EmptyState>
  }
  if (MARKDOWN_FIELDS.has(field)) {
    return (
      <MarkdownPreview
        emptyState={<EmptyState>{t("tool_update_empty")}</EmptyState>}
        linkifySlugs
        linkifyUrls
        maxChars={480}
        maxLines={4}
        text={typeof value === "string" ? value : ""}
      />
    )
  }
  if (value == null || value === "") return <EmptyState>{t("tool_update_empty")}</EmptyState>
  if (field === "confidence" && typeof value === "number") return <Badge>{Math.round(value * 100)}%</Badge>
  return <span className="break-words [overflow-wrap:anywhere]">{String(value).replace(/_/g, " ")}</span>
}

function ChangedFields({ input }: { input: Record<string, unknown> }) {
  const fields = FIELD_ORDER.filter((field) => Object.prototype.hasOwnProperty.call(input, field))
  if (fields.length === 0) return <EmptyState>{t("tool_update_no_fields")}</EmptyState>
  return (
    <div className="grid min-w-0 gap-2 sm:grid-cols-2">
      {fields.map((field) => {
        const wide = MARKDOWN_FIELDS.has(field) || field === "evidence"
        return (
          <div className={`min-w-0 rounded-md border border-border p-2 ${wide ? "sm:col-span-2" : ""}`} key={field}>
            <SectionLabel>{labelFor(field)}</SectionLabel>
            <FieldValue field={field} value={input[field]} />
          </div>
        )
      })}
    </div>
  )
}

function collapsedSummary(context: ToolCardContext) {
  if (context.resultError) return t("tool_update_failed")
  const id = insightId(context)
  return id ? t("tool_update_summary_with_id", { id }) : t("tool_update_summary")
}

function renderExpanded(context: ToolCardContext) {
  if (context.resultError) return <InsightErrorCard message={resultMessage(context) ?? t("tool_update_error")} />
  const id = insightId(context)
  const message = resultMessage(context)
  const reason = typeof context.input?.reason === "string" ? context.input.reason : ""
  const live = context.livePendingAction
  return (
    <CardShell>
      <div className="flex min-w-0 flex-wrap items-center gap-2">
        <SectionLabel>{t("tool_update_label")}</SectionLabel>
        {id ? <EntityReference id={id} kind="insight" slug={`INSIGHT-${id}`} wrap="nowrap" /> : null}
        {live ? <StatePill state={live.state} /> : null}
      </div>
      {message ? <div className="break-words text-xs text-text-muted">{message}</div> : null}
      {live?.detail || live?.label ? <div className="break-words text-xs text-text-muted">{live.detail ?? live.label}</div> : null}
      <div>
        <SectionLabel>{t("tool_update_changed_fields")}</SectionLabel>
        <ChangedFields input={context.input ?? {}} />
      </div>
      <div>
        <SectionLabel>{t("tool_reason")}</SectionLabel>
        <MarkdownPreview
          emptyState={<EmptyState>{t("tool_update_reason_empty")}</EmptyState>}
          linkifySlugs
          linkifyUrls
          maxChars={480}
          maxLines={4}
          text={reason}
        />
      </div>
    </CardShell>
  )
}

const updateInsightToolCard: ToolCardRenderer = {
  toolName: "update_insight",
  collapsedSummary,
  renderExpanded
}

export const examples: ToolCardExample[] = [
  {
    id: "updated_fields",
    label: "Updated fields and Markdown reason",
    input: {
      target_insight_id: 41,
      title: "Repeated prepare failures",
      severity: "high",
      confidence: 0.92,
      evidence: [{ job_id: 200, run_id: 99, kind: "run_transcript" }],
      suggested_prompt: "Inspect **JOB-200** and https://example.test/runbook.",
      reason: "New evidence from **RUN-99** confirms the pattern."
    },
    resultBody: "Suggestion #41 updated."
  },
  { id: "pending_update", label: "Pending update", input: { target_insight_id: 41, memory_suggestion: null, reason: "Clear the obsolete memory suggestion." } },
  {
    id: "update_error",
    label: "Failed update",
    input: { target_insight_id: 41, severity: "high", reason: "Severity changed." },
    resultBody: "Suggestion #41 is accepted and cannot be updated.",
    resultError: true
  }
]

export default updateInsightToolCard
