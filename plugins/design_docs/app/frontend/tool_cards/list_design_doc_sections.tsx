import { CopyIcon } from "@app/components/CopyableSlug"
import { useCopyToClipboard } from "@app/hooks/useCopyToClipboard"
import { isPlainObject, type ToolCardContext, type ToolCardExample, type ToolCardRenderer } from "@app/pluginToolCards"
import { Badge, CardShell, displayValue, EmptyState, EntityReference, numberValue, Row, StatePill } from "@app/routes/chat/toolCardUi"
import { DesignDocErrorCard, DesignDocPendingCard, t } from "../designDocToolCard"

type DesignDocSection = { text: string; level: number; startOffset: number; endOffset: number }
type DesignDocOutline = {
  doc: {
    id: number | null
    docRef: string
    title: string
    visibility: string | null
    state: string | null
    repositoryIds: number[]
    version: number | null
    updatedAt: string | null
  }
  sections: DesignDocSection[]
  skippedCount: number
  readOnly: boolean | null
  referenceFormat: string | null
}

const INDENT_CLASS: Record<number, string> = { 1: "ml-0", 2: "ml-3", 3: "ml-6", 4: "ml-9", 5: "ml-12", 6: "ml-14" }
const OFFSET_BUTTON_CLASS = [
  "inline-flex h-8 w-8 shrink-0 items-center justify-center rounded",
  "text-text-subtle hover:bg-surface-raised hover:text-text-primary",
  "focus:outline-none focus:ring-2 focus:ring-brand"
].join(" ")

function parseSection(value: unknown): DesignDocSection | null {
  if (!isPlainObject(value)) return null
  const text = displayValue(value.text)
  const level = numberValue(value.level)
  const startOffset = numberValue(value.start_offset)
  const endOffset = numberValue(value.end_offset)
  if (!text || level == null || startOffset == null || endOffset == null) return null
  return { text, level, startOffset, endOffset }
}

function sectionsResult(context: ToolCardContext): DesignDocOutline | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed) || !isPlainObject(parsed.design_doc) || !Array.isArray(parsed.sections)) return null
  const docRef = displayValue(parsed.design_doc.doc_ref)
  const title = displayValue(parsed.design_doc.title)
  if (!docRef || !title) return null
  const sections = parsed.sections.map(parseSection).filter((section): section is DesignDocSection => section !== null)
  const repositoryIds = Array.isArray(parsed.design_doc.repository_ids)
    ? parsed.design_doc.repository_ids.map(numberValue).filter((id): id is number => id !== null)
    : []
  return {
    doc: {
      id: numberValue(parsed.design_doc.id),
      docRef,
      title,
      visibility: displayValue(parsed.design_doc.visibility),
      state: displayValue(parsed.design_doc.state),
      repositoryIds,
      version: numberValue(parsed.design_doc.current_version_number),
      updatedAt: displayValue(parsed.design_doc.updated_at)
    },
    sections,
    skippedCount: parsed.sections.length - sections.length,
    readOnly: typeof parsed.read_only === "boolean" ? parsed.read_only : null,
    referenceFormat: displayValue(parsed.reference_format)
  }
}

function collapsedSummary(context: ToolCardContext) {
  const result = sectionsResult(context)
  if (context.resultError && !result) return t("tool_sections_error_summary")
  if (!context.resultBody && context.parsedResult == null) return t("tool_sections_pending_summary")
  if (!result) return null
  return t("tool_section_count", { doc: result.doc.docRef, count: result.sections.length })
}

function Offset({ value }: { value: number }) {
  const { copied, copy } = useCopyToClipboard()
  const label = String(value)
  return (
    <span className="inline-flex items-center gap-0.5">
      <span>{label}</span>
      <button
        aria-label={t("tool_copy_offset", { offset: label })}
        className={OFFSET_BUTTON_CLASS}
        onClick={() => copy(label)}
        title={copied ? t("tool_offset_copied") : t("tool_copy_offset", { offset: label })}
        type="button"
      >
        <CopyIcon className={`h-3.5 w-3.5 ${copied ? "text-success-text" : ""}`} />
      </button>
    </span>
  )
}

function renderExpanded(context: ToolCardContext) {
  const result = sectionsResult(context)
  if (context.resultError && !result) {
    return <DesignDocErrorCard message={displayValue(context.resultBody) ?? t("tool_unknown_error")} title={t("tool_sections_title")} />
  }
  if (!context.resultBody && context.parsedResult == null) return <DesignDocPendingCard title={t("tool_sections_title")} />
  if (!result) return null

  const inputDocRef = displayValue(context.input?.doc_ref)
  const inputQuery = displayValue(context.input?.query)
  const inputFilters = context.input?.filters == null ? null : (displayValue(context.input.filters) ?? JSON.stringify(context.input.filters))
  const docId = result.doc.id ?? numberValue(result.doc.docRef.match(/(\d+)\s*$/)?.[1])

  return (
    <CardShell>
      {inputDocRef || inputQuery || inputFilters ? (
        <div className="flex flex-wrap items-end gap-3">
          {inputDocRef ? (
            <div>
              <div className="text-2xs font-medium text-text-muted">{t("tool_document")}</div>
              <EntityReference id={numberValue(inputDocRef.match(/(\d+)\s*$/)?.[1])} kind="design_doc" label={inputDocRef} slug={inputDocRef} wrap="nowrap" />
            </div>
          ) : null}
          {inputQuery ? <Row label={t("tool_filter_query")} value={inputQuery} /> : null}
          {inputFilters ? <Row label={t("tool_filters")} value={inputFilters} /> : null}
        </div>
      ) : null}

      <div className="flex flex-wrap items-center gap-2">
        <EntityReference id={docId} kind="design_doc" label={result.doc.docRef} slug={result.doc.docRef} wrap="nowrap" />
        {result.doc.state ? <StatePill state={result.doc.state} /> : null}
        {result.doc.visibility ? <Badge>{result.doc.visibility}</Badge> : null}
        {result.readOnly != null ? <Badge>{result.readOnly ? t("read_only") : t("tool_editable")}</Badge> : null}
        {result.doc.version != null ? <Badge>{t("tool_version", { number: result.doc.version })}</Badge> : null}
      </div>
      <div className="break-words text-sm font-medium text-text-primary">{result.doc.title}</div>
      <div className="flex flex-wrap items-center gap-x-3 gap-y-1 text-xs text-text-muted">
        {result.doc.updatedAt ? <span>{t("tool_updated", { value: result.doc.updatedAt })}</span> : null}
        {result.referenceFormat ? <span>{t("tool_reference_format", { value: result.referenceFormat })}</span> : null}
        {result.doc.repositoryIds.map((id) => (
          <EntityReference key={id} kind="repository" label={t("tool_repository_number", { id })} repositoryId={id} />
        ))}
      </div>

      {result.skippedCount > 0 ? (
        <div className="rounded-[var(--radius-panel)] border border-warning/30 bg-warning/10 px-2 py-1 text-xs text-warning-text" role="status">
          {t("tool_sections_skipped", { count: result.skippedCount })}
        </div>
      ) : null}

      {result.sections.length > 0 ? (
        <ol className="space-y-1 rounded-[var(--radius-panel)] border border-border bg-surface p-2 text-xs">
          {result.sections.map((section, index) => (
            <li
              className="flex min-w-0 flex-col gap-1 border-b border-border/60 py-1 last:border-b-0 sm:flex-row sm:items-start sm:gap-2"
              key={`${section.startOffset}-${index}`}
            >
              <span className="shrink-0 font-mono text-text-muted">H{section.level}</span>
              <span
                className={`min-w-0 flex-1 whitespace-normal break-words border-l border-border pl-2 text-text-primary ${INDENT_CLASS[Math.min(Math.max(section.level, 1), 6)]}`}
              >
                {section.text}
              </span>
              <span
                className="flex shrink-0 items-center self-end font-mono text-text-muted sm:self-start"
                aria-label={t("tool_offset_range", { start: section.startOffset, end: section.endOffset })}
              >
                <Offset value={section.startOffset} />
                <span aria-hidden="true">–</span>
                <Offset value={section.endOffset} />
              </span>
            </li>
          ))}
        </ol>
      ) : (
        <EmptyState>{t("tool_no_sections")}</EmptyState>
      )}
    </CardShell>
  )
}

const listDesignDocSectionsToolCard: ToolCardRenderer = { toolName: "list_design_doc_sections", collapsedSummary, renderExpanded }
export default listDesignDocSectionsToolCard

export const examples: ToolCardExample[] = [
  {
    id: "nested_sections",
    label: "Nested Sections",
    description: "A read-only outline with nested, wrapping headings, copyable offsets, input filters, and one malformed row.",
    input: { doc_ref: "DOC-34", query: "attention", filters: { level: [1, 2] } },
    parsedResult: {
      design_doc: {
        id: 34,
        doc_ref: "DOC-34",
        title: "Operator Briefing",
        state: "draft",
        visibility: "private",
        repository_ids: [1],
        current_version_number: 45,
        updated_at: "2026-10-18T10:00:00Z"
      },
      sections: [
        { text: "Operator Briefing", level: 1, start_offset: 0, end_offset: 128 },
        { text: "Attention Debt With a Long Heading That Wraps on Narrow Screens", level: 2, start_offset: 24, end_offset: 128 },
        { text: "Missing offsets", level: 3 }
      ],
      read_only: true,
      reference_format: "DOC-34"
    }
  },
  {
    id: "no_sections",
    label: "No Sections",
    description: "A valid document with no Markdown headings.",
    input: { doc_ref: "DOC-34" },
    parsedResult: {
      design_doc: { id: 34, doc_ref: "DOC-34", title: "Operator Briefing", state: "draft", visibility: "private", repository_ids: [] },
      sections: [],
      read_only: false,
      reference_format: "DOC-34"
    }
  },
  {
    id: "not_found",
    label: "Design Doc Not Found",
    resultBody: "Error: design doc not found in this agent context: DOC-999",
    resultError: true
  }
]
