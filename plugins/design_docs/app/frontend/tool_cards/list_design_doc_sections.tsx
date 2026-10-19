import { CopyIcon } from "@app/components/CopyableSlug"
import { useCopyToClipboard } from "@app/hooks/useCopyToClipboard"
import { isPlainObject, type ToolCardContext, type ToolCardExample, type ToolCardRenderer } from "@app/pluginToolCards"
import { Badge, CardShell, displayValue, EmptyState, EntityReference, Row, StatePill, numberValue } from "@app/routes/chat/toolCardUi"
import { DesignDocErrorCard, DesignDocPendingCard, parseDesignDocSummary, t, type DesignDocSummary } from "../designDocToolCard"

type DesignDocSection = { text: string; level: number; startOffset: number; endOffset: number }

type ListDesignDocSections = {
  summary: DesignDocSummary
  sections: DesignDocSection[]
  skippedSections: number
  readOnly: boolean | null
  referenceFormat: string | null
  repositoryIds: number[]
  version: number | null
  updatedAt: string | null
}

const LEVEL_INDENT_CLASS: Record<number, string> = {
  1: "",
  2: "pl-2 sm:pl-3",
  3: "pl-4 sm:pl-6",
  4: "pl-6 sm:pl-9",
  5: "pl-8 sm:pl-12",
  6: "pl-10 sm:pl-15"
}

const OFFSET_COPY_BUTTON_CLASS = [
  "inline-flex h-9 w-9 shrink-0 items-center justify-center rounded sm:h-7 sm:w-7",
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
  if (!Number.isInteger(level) || level < 1 || level > 6) return null
  if (!Number.isInteger(startOffset) || startOffset < 0 || !Number.isInteger(endOffset) || endOffset < startOffset) return null

  return { text, level, startOffset, endOffset }
}

function sectionsResult(context: ToolCardContext): ListDesignDocSections | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed) || !isPlainObject(parsed.design_doc) || !Array.isArray(parsed.sections)) return null

  const summary = parseDesignDocSummary(parsed.design_doc)
  if (!summary) return null

  const sections = parsed.sections.map(parseSection).filter((section): section is DesignDocSection => section !== null)
  return {
    summary,
    sections,
    skippedSections: parsed.sections.length - sections.length,
    readOnly: typeof parsed.read_only === "boolean" ? parsed.read_only : null,
    referenceFormat: displayValue(parsed.reference_format),
    repositoryIds: Array.isArray(parsed.design_doc.repository_ids)
      ? parsed.design_doc.repository_ids.map(numberValue).filter((id): id is number => id !== null)
      : [],
    version: numberValue(parsed.design_doc.current_version_number),
    updatedAt: displayValue(parsed.design_doc.updated_at)
  }
}

function collapsedSummary(context: ToolCardContext) {
  const result = sectionsResult(context)
  if (context.resultError && !result) return t("tool_sections_error_summary")
  if (!context.resultBody && context.parsedResult == null) return t("tool_sections_pending_summary")
  if (!result) return null
  return t("tool_section_count", { doc: result.summary.docRef, count: result.sections.length })
}

function OffsetCopyButton({ label, value }: { label: string; value: number }) {
  const { copied, copy } = useCopyToClipboard()

  return (
    <button
      aria-label={t("tool_copy_offset", { label, value })}
      className={OFFSET_COPY_BUTTON_CLASS}
      onClick={() => copy(String(value))}
      title={copied ? t("tool_offset_copied") : t("tool_copy_offset", { label, value })}
      type="button"
    >
      <CopyIcon className={`h-3.5 w-3.5 ${copied ? "text-success-text" : ""}`} />
    </button>
  )
}

function inputRows(context: ToolCardContext) {
  return [
    context.input?.doc_ref != null ? { label: t("tool_filter_doc_ref"), value: String(context.input.doc_ref) } : null,
    context.input?.query != null ? { label: t("tool_filter_query"), value: String(context.input.query) } : null,
    context.input?.filters != null
      ? { label: t("tool_filters"), value: typeof context.input.filters === "string" ? context.input.filters : JSON.stringify(context.input.filters) }
      : null
  ].filter((row): row is { label: string; value: string } => row !== null)
}

function renderExpanded(context: ToolCardContext) {
  const result = sectionsResult(context)
  if (context.resultError && !result) {
    return <DesignDocErrorCard message={displayValue(context.resultBody) ?? t("tool_unknown_error")} title={t("tool_sections_title")} />
  }
  if (!context.resultBody && context.parsedResult == null) return <DesignDocPendingCard title={t("tool_sections_title")} />
  if (!result) return null

  const docId = result.summary.docRef.match(/(\d+)\s*$/)?.[1]
  const inputs = inputRows(context)

  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <EntityReference id={docId} kind="design_doc" label={result.summary.docRef} slug={result.summary.docRef} wrap="nowrap" />
        <Badge>{t("tool_sections")}</Badge>
        {result.summary.state ? <StatePill state={result.summary.state} /> : null}
        {result.summary.visibility ? <Badge>{result.summary.visibility}</Badge> : null}
        {result.readOnly != null ? <Badge>{result.readOnly ? t("read_only") : t("tool_writable")}</Badge> : null}
      </div>
      <div className="whitespace-normal break-words text-sm font-medium text-text-primary">{result.summary.title}</div>
      {result.version != null || result.updatedAt ? (
        <div className="flex flex-wrap items-center gap-2 text-xs text-text-muted">
          {result.version != null ? <Badge>{t("tool_version", { number: result.version })}</Badge> : null}
          {result.updatedAt ? <span>{t("tool_updated", { value: result.updatedAt })}</span> : null}
        </div>
      ) : null}
      {result.repositoryIds.length > 0 ? (
        <div className="flex flex-wrap items-center gap-1 text-xs">
          <span className="text-text-muted">{t("tool_repositories")}</span>
          {result.repositoryIds.map((id) => (
            <EntityReference key={id} kind="repository" label={t("tool_repository_number", { id })} repositoryId={id} />
          ))}
        </div>
      ) : null}
      {inputs.length > 0 || result.referenceFormat ? (
        <div className="flex flex-wrap items-end gap-3">
          {inputs.map((row) => (
            <Row key={row.label} label={row.label} value={row.value} />
          ))}
          {result.referenceFormat ? <Row label={t("tool_reference_format")} value={result.referenceFormat} /> : null}
        </div>
      ) : null}
      {result.skippedSections > 0 ? (
        <div className="rounded-[var(--radius-panel)] border border-warning/30 bg-warning/10 px-2 py-1 text-xs text-warning-text" role="status">
          {t("tool_skipped_sections", { count: result.skippedSections })}
        </div>
      ) : null}
      {result.sections.length > 0 ? (
        <ol className="space-y-1 rounded-[var(--radius-panel)] border border-border bg-surface p-2 text-xs">
          {result.sections.map((section, index) => (
            <li className="flex min-w-0 items-start gap-2 border-b border-border py-1 last:border-b-0" key={`${section.startOffset}-${index}`}>
              <span className="pt-1 font-mono text-text-muted">H{section.level}</span>
              <span className={`min-w-0 flex-1 whitespace-normal break-words pt-1 text-text-primary ${LEVEL_INDENT_CLASS[section.level]}`}>{section.text}</span>
              <span className="flex shrink-0 items-center gap-0.5 font-mono text-text-muted">
                <span>{section.startOffset}</span>
                <OffsetCopyButton label={t("tool_start_offset")} value={section.startOffset} />
                <span aria-hidden="true">–</span>
                <span>{section.endOffset}</span>
                <OffsetCopyButton label={t("tool_end_offset")} value={section.endOffset} />
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
    description: "Long nested headings, copyable offsets, request metadata, and a malformed row warning.",
    input: { doc_ref: "DOC-34", query: "attention", filters: { level: [1, 2, 3] } },
    parsedResult: {
      design_doc: {
        doc_ref: "DOC-34",
        title: "Operator Briefing: AI-Generated Cross-Repo Overview and Attention-Debt Surface",
        state: "draft",
        visibility: "private"
      },
      sections: [
        { text: "Operator Briefing", level: 1, start_offset: 0, end_offset: 128 },
        { text: "A deliberately long nested heading that demonstrates wrapping instead of truncation", level: 3, start_offset: 24, end_offset: 128 },
        { text: "Malformed", level: 9, start_offset: 128, end_offset: 129 }
      ],
      read_only: true,
      reference_format: "DOC-34"
    }
  },
  {
    id: "no_sections",
    label: "No Sections",
    input: { doc_ref: "DOC-34" },
    parsedResult: { design_doc: { doc_ref: "DOC-34", title: "Empty outline" }, sections: [], read_only: false, reference_format: "DOC-34" }
  },
  { id: "not_found", label: "Not Found", resultBody: "Error: design doc not found in this agent context: DOC-999", resultError: true }
]
