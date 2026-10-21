import type { ReactNode } from "react"
import i18n from "i18next"
import { DescriptionList, Pill, Surface, Text } from "@app/components/ui"
import { useT } from "@app/hooks/useT"
import { isPlainObject, type ToolCardContext, type ToolCardExample, type ToolCardRenderer } from "@app/pluginToolCards"
import { CardShell, displayValue, EmptyState, EntityReference, SectionLabel, StatePill } from "@app/routes/chat/toolCardUi"
import { InsightErrorCard, TextPreview } from "../agentInsightToolCard"

const MARKDOWN_FIELDS = ["summary", "suggested_prompt", "memory_suggestion", "stale_memory_text", "stale_memory_evidence"] as const
const SIMPLE_FIELDS = ["title", "category", "severity", "confidence", "proposal_type"] as const

function resultMessage(value: unknown): string | null {
  if (typeof value === "string") {
    const text = value.trim()
    if (!text) return null
    try {
      return resultMessage(JSON.parse(text)) ?? text
    } catch {
      return text
    }
  }
  if (!isPlainObject(value)) return null
  for (const key of ["message", "structured_content", "structuredContent", "data"]) {
    const message = resultMessage(value[key])
    if (message) return message
  }
  if (Array.isArray(value.content)) {
    for (const item of value.content) {
      const message = isPlainObject(item) ? resultMessage(item.text) : resultMessage(item)
      if (message) return message
    }
  }
  return null
}

function targetId(context: ToolCardContext) {
  const resultIds = isPlainObject(context.parsedResult) && Array.isArray(context.parsedResult.insight_ids) ? context.parsedResult.insight_ids : []
  return (
    displayValue(context.input?.target_insight_id) ?? displayValue(resultIds[0]) ?? resultMessage(context.parsedResult)?.match(/Suggestion #(\d+)/)?.[1] ?? null
  )
}

function errorMessage(context: ToolCardContext) {
  return resultMessage(context.parsedResult) ?? resultMessage(context.resultBody) ?? i18n.t("agent_insights:tool_update_error")
}

function hasOwn(input: Record<string, unknown>, key: string) {
  return Object.prototype.hasOwnProperty.call(input, key)
}

function fieldLabel(key: string) {
  return i18n.t(`agent_insights:tool_update_field_${key}`)
}

function displaySimpleValue(key: string, value: unknown) {
  if (value == null || value === "") return i18n.t("agent_insights:tool_update_cleared")
  if (key === "confidence" && typeof value === "number") return `${Math.round(value * 100)}%`
  return displayValue(value) ?? String(value)
}

function runSlugHrefOverrides(text: string) {
  return Object.fromEntries(Array.from(text.matchAll(/\bRUN-(\d+)\b/g), (match) => [match[0], `/admin/runs/${match[1]}/transcript`]))
}

function EvidenceValue({ value }: { value: unknown }) {
  const { t } = useT("agent_insights")
  if (!Array.isArray(value) || value.length === 0) return <EmptyState>{t("tool_update_no_evidence")}</EmptyState>

  return (
    <ul className="space-y-1">
      {value.map((entry, index) => {
        if (!isPlainObject(entry)) return <li key={index}>{displayValue(entry) ?? t("tool_update_empty_value")}</li>
        const jobId = displayValue(entry.job_id)
        const runId = displayValue(entry.run_id)
        return (
          <li className="flex min-w-0 flex-wrap items-center gap-2" key={`${jobId ?? "job"}-${runId ?? "run"}-${index}`}>
            {displayValue(entry.kind) ? <Pill>{displayValue(entry.kind)!.replace(/_/g, " ")}</Pill> : null}
            {jobId ? <EntityReference id={jobId} kind="job" wrap="nowrap" /> : null}
            {runId ? <EntityReference href={`/admin/runs/${runId}/transcript`} id={runId} kind="run" wrap="nowrap" /> : null}
          </li>
        )
      })}
    </ul>
  )
}

function ChangedFields({ input }: { input: Record<string, unknown> }) {
  const { t } = useT("agent_insights")
  const fields: ReactNode[] = []

  for (const key of SIMPLE_FIELDS) {
    if (!hasOwn(input, key)) continue
    fields.push(
      <DescriptionList.Item descriptionClassName="min-w-0 break-words [overflow-wrap:anywhere]" key={key} label={fieldLabel(key)}>
        {displaySimpleValue(key, input[key])}
      </DescriptionList.Item>
    )
  }
  if (hasOwn(input, "target_memory_id")) {
    const id = displayValue(input.target_memory_id)
    fields.push(
      <DescriptionList.Item key="target_memory_id" label={fieldLabel("target_memory_id")}>
        {id ? <EntityReference id={id} kind="memory" wrap="nowrap" /> : t("tool_update_cleared")}
      </DescriptionList.Item>
    )
  }

  const markdown = MARKDOWN_FIELDS.filter((key) => hasOwn(input, key))
  const evidence = hasOwn(input, "evidence")
  if (fields.length === 0 && markdown.length === 0 && !evidence) return <EmptyState>{t("tool_update_no_changes")}</EmptyState>

  return (
    <div className="space-y-3">
      {fields.length ? (
        <DescriptionList.Root className="sm:grid-cols-2" density="compact">
          {fields}
        </DescriptionList.Root>
      ) : null}
      {markdown.map((key) => (
        <Surface className="min-w-0 overflow-hidden" key={key} padding="sm" variant="inset">
          <TextPreview
            emptyState={<Text muted>{t("tool_update_empty_text")}</Text>}
            maxChars={480}
            slugHrefOverrides={runSlugHrefOverrides(typeof input[key] === "string" ? input[key] : "")}
            text={typeof input[key] === "string" ? input[key] : ""}
            title={fieldLabel(key)}
          />
        </Surface>
      ))}
      {evidence ? (
        <Surface className="min-w-0 overflow-hidden" padding="sm" variant="inset">
          <SectionLabel>{fieldLabel("evidence")}</SectionLabel>
          <EvidenceValue value={input.evidence} />
        </Surface>
      ) : null}
    </div>
  )
}

function collapsedSummary(context: ToolCardContext) {
  if (context.resultError) return i18n.t("agent_insights:tool_update_failed")
  const id = targetId(context)
  const pending = context.parsedResult == null && !resultMessage(context.resultBody)
  if (pending) return id ? i18n.t("agent_insights:tool_update_pending_with_id", { id }) : i18n.t("agent_insights:tool_update_pending")
  return id ? i18n.t("agent_insights:tool_update_summary_with_id", { id }) : i18n.t("agent_insights:tool_update_summary")
}

function UpdateInsightCard({ context }: { context: ToolCardContext }) {
  const { t } = useT("agent_insights")
  const input = context.input ?? {}
  const id = targetId(context)
  const message = resultMessage(context.parsedResult) ?? resultMessage(context.resultBody)

  return (
    <CardShell>
      <div className="flex min-w-0 flex-wrap items-center gap-2">
        <SectionLabel>{t("tool_update_label")}</SectionLabel>
        {!message && context.livePendingAction ? <StatePill state={context.livePendingAction.state} /> : null}
      </div>
      {message ? <Text className="break-words [overflow-wrap:anywhere]">{message}</Text> : <Text muted>{t("tool_update_awaiting_result")}</Text>}
      {id ? (
        <DescriptionList.Root density="compact">
          <DescriptionList.Item label={t("tool_insight")}>
            <EntityReference id={id} kind="insight" slug={`INSIGHT-${id}`} wrap="nowrap" />
          </DescriptionList.Item>
        </DescriptionList.Root>
      ) : null}
      <div>
        <SectionLabel>{t("tool_update_changed_fields")}</SectionLabel>
        <ChangedFields input={input} />
      </div>
      <div>
        <SectionLabel>{t("tool_reason")}</SectionLabel>
        <TextPreview
          emptyState={<Text muted>{t("tool_update_no_reason")}</Text>}
          maxChars={480}
          slugHrefOverrides={runSlugHrefOverrides(typeof input.reason === "string" ? input.reason : "")}
          text={typeof input.reason === "string" ? input.reason : ""}
          title={t("tool_reason")}
        />
      </div>
    </CardShell>
  )
}

function renderExpanded(context: ToolCardContext) {
  if (context.resultError) return <InsightErrorCard message={errorMessage(context)} />
  return <UpdateInsightCard context={context} />
}

const updateInsightToolCard: ToolCardRenderer = {
  toolName: "update_insight",
  collapsedSummary,
  renderExpanded
}

export default updateInsightToolCard

export const examples: ToolCardExample[] = [
  {
    id: "all_changed_fields",
    label: "All insight fields changed",
    input: {
      target_insight_id: 41,
      reason: "New **RUN-99** evidence changes the recommendation. See https://example.test/evidence.",
      title: "Prepare failures share one cause",
      summary: "Failures now point to **JOB-200**.",
      category: "repeated_failure",
      severity: "high",
      confidence: 0.94,
      proposal_type: "create_job",
      evidence: [{ job_id: 200, run_id: 99, kind: "run_transcript" }],
      suggested_prompt: "Fix **JOB-200** and verify the prepare path.",
      memory_suggestion: "Remember the shared Bundler setup.",
      target_memory_id: 12,
      stale_memory_text: "The old setup always succeeds.",
      stale_memory_evidence: "It failed in **RUN-99**."
    },
    resultBody: "Suggestion #41 updated."
  },
  {
    id: "partial_update_codex_envelope",
    label: "Partial update in a Codex envelope",
    sourceType: "codex",
    input: { target_insight_id: 42, reason: "Confidence increased.", confidence: 0.81 },
    parsedResult: { content: [{ type: "text", text: "Suggestion #42 updated." }] }
  },
  {
    id: "pending_update",
    label: "Pending update",
    input: { target_insight_id: 43, reason: "", memory_suggestion: null }
  },
  {
    id: "error",
    label: "Failed update",
    input: { target_insight_id: 44, reason: "Refresh the insight.", title: "New title" },
    resultBody: "Suggestion #44 is accepted and cannot be updated.",
    resultError: true
  }
]
