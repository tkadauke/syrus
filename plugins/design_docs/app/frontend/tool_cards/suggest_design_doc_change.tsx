import { isPlainObject, type ToolCardContext, type ToolCardExample, type ToolCardRenderer } from "@app/pluginToolCards"
import { MarkdownPreview } from "@app/routes/chat/toolCardMarkdown"
import { Badge, CardShell, displayValue, EntityReference, numberValue, Row, StatePill } from "@app/routes/chat/toolCardUi"
import { DesignDocErrorCard, DesignDocHeader, DesignDocPendingCard, parseDesignDocSummary, t, type DesignDocSummary } from "../designDocToolCard"

type Suggestion = {
  state: string | null
  changeType: string | null
  changeSummary: string
  conflictReason: string
  suggestedByKind: string | null
  suggestedBy: { id: number | null; name: string | null; emailAddress: string | null } | null
  originalMarkdown: string
  proposedMarkdown: string
  baseVersionNumber: number | null
  occurrenceIndex: number | null
  anchor: Record<string, unknown> | null
  thread: Record<string, unknown> | null
}
type SuggestDesignDocChange = { summary: DesignDocSummary; suggestion: Suggestion; versionNumber: number | null }

function textValue(value: unknown) {
  return typeof value === "string" ? value : ""
}

function authorValue(value: unknown): Suggestion["suggestedBy"] {
  if (!isPlainObject(value)) return null
  const id = numberValue(value.id)
  const name = displayValue(value.name)
  const emailAddress = displayValue(value.email_address)
  return id != null || name != null || emailAddress != null ? { id, name, emailAddress } : null
}

function resultObject(parsed: unknown): Record<string, unknown> | null {
  if (!isPlainObject(parsed)) return null
  if (isPlainObject(parsed.design_doc) || isPlainObject(parsed.suggestion)) return parsed
  for (const key of ["result", "data"]) if (isPlainObject(parsed[key])) return parsed[key] as Record<string, unknown>
  if (Array.isArray(parsed.content)) {
    const entry = parsed.content.find((item) => isPlainObject(item) && item.type === "text" && typeof item.text === "string")
    if (isPlainObject(entry)) {
      try {
        const decoded = JSON.parse(String(entry.text))
        return isPlainObject(decoded) ? decoded : null
      } catch {
        return null
      }
    }
  }
  return null
}

function suggestDesignDocChange(context: ToolCardContext): SuggestDesignDocChange | null {
  const parsed = resultObject(context.parsedResult)
  if (!parsed || !isPlainObject(parsed.design_doc) || !isPlainObject(parsed.suggestion)) return null
  const summary = parseDesignDocSummary(parsed.design_doc)
  if (!summary) return null
  const suggestion = parsed.suggestion
  const version = isPlainObject(parsed.version) ? parsed.version : null
  return {
    summary,
    versionNumber: numberValue(version?.version_number),
    suggestion: {
      state: displayValue(suggestion.state),
      changeType: displayValue(suggestion.change_type),
      changeSummary: textValue(suggestion.change_summary),
      conflictReason: textValue(suggestion.conflict_reason),
      suggestedByKind: displayValue(suggestion.suggested_by_kind),
      suggestedBy: authorValue(suggestion.suggested_by),
      originalMarkdown: textValue(suggestion.original_markdown),
      proposedMarkdown: textValue(suggestion.proposed_markdown ?? suggestion.suggested_markdown),
      baseVersionNumber: numberValue(suggestion.base_version_number) ?? numberValue(context.input?.base_version_number),
      occurrenceIndex: numberValue(suggestion.occurrence_index) ?? numberValue(context.input?.occurrence_index),
      anchor: isPlainObject(suggestion.anchor) ? suggestion.anchor : null,
      thread: isPlainObject(suggestion.thread) ? suggestion.thread : null
    }
  }
}

function errorMessage(context: ToolCardContext): string {
  if (isPlainObject(context.parsedResult)) {
    for (const key of ["error", "message"]) {
      const value = displayValue(context.parsedResult[key])
      if (value) return value
    }
  }
  return displayValue(context.resultBody) ?? t("tool_unknown_error")
}

function collapsedSummary(context: ToolCardContext) {
  const result = suggestDesignDocChange(context)
  if (context.resultError && !result) return t("tool_suggestion_error_summary")
  if (!context.resultBody && context.parsedResult == null) return t("tool_suggestion_pending_summary")
  if (!result) return null
  return t("tool_suggested_change_summary", { doc: result.summary.docRef, state: result.suggestion.state ? ` (${result.suggestion.state})` : "" })
}

function renderExpanded(context: ToolCardContext) {
  const result = suggestDesignDocChange(context)
  if (context.resultError && !result) return <DesignDocErrorCard message={errorMessage(context)} title={t("tool_suggestion_title")} />
  if (!context.resultBody && context.parsedResult == null) return <DesignDocPendingCard title={t("tool_suggestion_title")} />
  if (!result) return null
  const { suggestion } = result
  const anchorStart = numberValue(suggestion.anchor?.start_offset ?? context.input?.start_offset)
  const anchorEnd = numberValue(suggestion.anchor?.end_offset ?? context.input?.end_offset)
  const anchorKind = displayValue(suggestion.anchor?.anchor_kind)
  const anchorStatus = displayValue(suggestion.anchor?.status)
  const threadId = numberValue(suggestion.thread?.id ?? context.input?.thread_id)
  const threadState = displayValue(suggestion.thread?.state)
  const docId = numberValue(result.summary.docRef.match(/(\d+)\s*$/)?.[1])

  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <Badge>{t("tool_suggestion")}</Badge>
        {suggestion.state ? <StatePill state={suggestion.state} /> : null}
        {suggestion.changeType ? <Badge>{suggestion.changeType.replace(/_/g, " ")}</Badge> : null}
      </div>
      <DesignDocHeader doc={result.summary} />
      <div className="break-words text-sm font-medium text-text-primary">{result.summary.title}</div>
      <dl className="grid min-w-0 gap-2 sm:grid-cols-2 lg:grid-cols-3">
        {suggestion.suggestedByKind ? <Row label={t("tool_suggested_by")} value={suggestion.suggestedByKind} /> : null}
        {suggestion.suggestedBy ? (
          <div className="min-w-0">
            <div className="text-2xs font-medium text-text-muted">{t("tool_author")}</div>
            <div className="flex min-w-0 flex-wrap items-center gap-x-2 text-xs">
              {suggestion.suggestedBy.name ? <span className="break-words font-medium text-text-primary">{suggestion.suggestedBy.name}</span> : null}
              {suggestion.suggestedBy.emailAddress ? (
                <a className="break-all text-brand hover:underline" href={`mailto:${suggestion.suggestedBy.emailAddress}`}>
                  {suggestion.suggestedBy.emailAddress}
                </a>
              ) : null}
              {!suggestion.suggestedBy.name && !suggestion.suggestedBy.emailAddress && suggestion.suggestedBy.id != null ? (
                <span className="font-mono text-text-muted">#{suggestion.suggestedBy.id}</span>
              ) : null}
            </div>
          </div>
        ) : null}
        {result.versionNumber != null ? <Row label={t("tool_version_label")} value={String(result.versionNumber)} /> : null}
        {suggestion.baseVersionNumber != null ? <Row label={t("tool_base_version")} value={String(suggestion.baseVersionNumber)} /> : null}
        {suggestion.occurrenceIndex != null ? <Row label={t("tool_occurrence")} value={String(suggestion.occurrenceIndex)} /> : null}
        {anchorKind || anchorStart != null || anchorEnd != null ? (
          <Row
            label={t("tool_anchor")}
            value={[anchorKind, anchorStart != null && anchorEnd != null ? `${anchorStart}–${anchorEnd}` : null].filter(Boolean).join(" · ")}
          />
        ) : null}
        {anchorStatus ? <Row label={t("tool_anchor_state")} value={anchorStatus} /> : null}
      </dl>
      {threadId != null ? (
        <div className="flex flex-wrap items-center gap-2 text-xs">
          <span className="text-text-muted">{t("tool_thread")}</span>
          <EntityReference
            href={`/design_docs/${docId ?? result.summary.docRef}?thread=${threadId}`}
            id={threadId}
            kind="design_doc"
            label={t("tool_thread_number", { id: threadId })}
          />
          {threadState ? <StatePill state={threadState} /> : null}
        </div>
      ) : null}
      <MarkdownPreview emptyState={t("tool_no_summary")} linkifyUrls maxChars={900} text={suggestion.changeSummary} title={t("tool_summary")} />
      {suggestion.conflictReason ? (
        <div className="rounded-[var(--radius-panel)] border border-warning/30 bg-warning/10 p-2 text-warning-text">
          <MarkdownPreview linkifyUrls maxChars={900} text={suggestion.conflictReason} title={t("tool_conflict")} />
        </div>
      ) : null}
      <div className="grid min-w-0 gap-2 lg:grid-cols-2">
        <div className="min-w-0 overflow-hidden rounded-[var(--radius-panel)] border border-danger/20 bg-danger/5 p-2">
          <MarkdownPreview
            emptyState={t("tool_empty_original")}
            linkifyUrls
            maxChars={1_500}
            maxLines={12}
            text={suggestion.originalMarkdown}
            title={t("tool_before")}
          />
        </div>
        <div className="min-w-0 overflow-hidden rounded-[var(--radius-panel)] border border-success/20 bg-success/5 p-2">
          <MarkdownPreview
            emptyState={t("tool_empty_proposed")}
            linkifyUrls
            maxChars={1_500}
            maxLines={12}
            text={suggestion.proposedMarkdown}
            title={t("tool_after")}
          />
        </div>
      </div>
    </CardShell>
  )
}

const suggestDesignDocChangeToolCard: ToolCardRenderer = { toolName: "suggest_design_doc_change", collapsedSummary, renderExpanded }
export default suggestDesignDocChangeToolCard

const exampleResult = {
  design_doc: { doc_ref: "DOC-20", title: "Target Graphs", visibility: "public", state: "draft" },
  suggestion: {
    state: "pending",
    change_type: "block_edit",
    suggested_by_kind: "agent",
    suggested_by: { id: 8, name: "Ada Lovelace", email_address: "ada@example.test" },
    original_markdown: "## Old heading\nOld wording.",
    proposed_markdown: "## New heading\nImproved wording for DOC-29.",
    change_summary: "Clarifies **target discovery**.",
    base_version_number: 4,
    occurrence_index: 2,
    anchor: { anchor_kind: "range", start_offset: 120, end_offset: 148, status: "active" },
    thread: { id: 17, state: "open" },
    conflict_reason: null
  },
  version: { version_number: 5 }
}

export const examples: ToolCardExample[] = [
  { id: "pending_suggestion", label: "Pending suggestion", input: { base_version_number: 4, occurrence_index: 2 }, parsedResult: exampleResult },
  {
    id: "empty_replacement",
    label: "Delete-only suggestion",
    parsedResult: { ...exampleResult, suggestion: { ...exampleResult.suggestion, proposed_markdown: "" } }
  },
  {
    id: "ambiguity_error",
    label: "Ambiguous selection error",
    resultError: true,
    resultBody: "original_markdown appears 2 times.\nOccurrence 1: start_offset=10, end_offset=15\nOccurrence 2: start_offset=40, end_offset=45"
  },
  {
    id: "stale_version_error",
    label: "Stale version error",
    resultError: true,
    parsedResult: { error: "stale design doc offsets: base_version_number 4 does not match current_version_number 5.\nRe-read the Design Doc." }
  },
  { id: "pending", label: "Pending result", resultBody: "" }
]
