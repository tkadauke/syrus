import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { Badge, CardShell, displayValue, EmptyState, EntityReference, numberValue } from "@app/routes/chat/toolCardUi"
import { parseDesignDocSummary, t, type DesignDocSummary } from "../designDocToolCard"

type DesignDocSection = {
  text: string
  level: number
  startOffset: number
  endOffset: number
}

type ListDesignDocSections = {
  summary: DesignDocSummary
  sections: DesignDocSection[]
}

function parseSection(value: unknown): DesignDocSection | null {
  if (!isPlainObject(value)) return null

  const text = displayValue(value.text)
  const level = numberValue(value.level)
  const startOffset = numberValue(value.start_offset)
  const endOffset = numberValue(value.end_offset)
  if (!text || level == null || startOffset == null || endOffset == null) return null

  return { text, level, startOffset, endOffset }
}

function sectionsResult(context: ToolCardContext): ListDesignDocSections | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed) || !isPlainObject(parsed.design_doc) || !Array.isArray(parsed.sections)) return null

  const summary = parseDesignDocSummary(parsed.design_doc)
  if (!summary) return null

  return { summary, sections: parsed.sections.map(parseSection).filter((section): section is DesignDocSection => section !== null) }
}

function collapsedSummary(context: ToolCardContext) {
  const result = sectionsResult(context)
  if (!result) return null

  return t("tool_section_count", { doc: result.summary.docRef, count: result.sections.length })
}

function renderExpanded(context: ToolCardContext) {
  const result = sectionsResult(context)
  if (!result) return null

  const docId = result.summary.docRef.match(/(\d+)\s*$/)?.[1]

  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <EntityReference id={docId} kind="design_doc" label={result.summary.docRef} slug={result.summary.docRef} wrap="nowrap" />
        <Badge>{t("tool_sections")}</Badge>
      </div>
      <div className="text-sm font-medium text-text-primary">{result.summary.title}</div>
      {result.sections.length > 0 ? (
        <ol className="space-y-1 rounded-[var(--radius-panel)] border border-border bg-surface p-2 text-xs">
          {result.sections.map((section, index) => (
            <li className="grid grid-cols-[auto_minmax(0,1fr)_auto] items-center gap-2" key={`${section.startOffset}-${index}`}>
              <span className="font-mono text-text-muted">H{section.level}</span>
              <span className="min-w-0 truncate text-text-primary" style={{ paddingLeft: `${Math.max(section.level - 1, 0) * 0.75}rem` }}>
                {section.text}
              </span>
              <span className="font-mono text-text-muted">
                {section.startOffset}-{section.endOffset}
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

const listDesignDocSectionsToolCard: ToolCardRenderer = {
  toolName: "list_design_doc_sections",
  collapsedSummary,
  renderExpanded
}

export default listDesignDocSectionsToolCard

export const examples = [
  {
    id: "nested_sections",
    label: "Nested Sections",
    parsedResult: {
      design_doc: { doc_ref: "DOC-34", title: "Operator Briefing", state: "draft", visibility: "private" },
      sections: [
        { text: "Operator Briefing", level: 1, start_offset: 0, end_offset: 128 },
        { text: "Attention Debt", level: 2, start_offset: 24, end_offset: 128 }
      ]
    }
  }
]
