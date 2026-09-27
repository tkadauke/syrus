import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { Badge, CardShell, displayValue, InternalLink, numberValue } from "@app/routes/chat/toolCardUi"
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

function docHref(docRef: string): string | null {
  const match = docRef.match(/(\d+)\s*$/)
  return match ? `/design_docs/${match[1]}` : null
}

function collapsedSummary(context: ToolCardContext) {
  const result = sectionsResult(context)
  if (!result) return null

  return t("tool_section_count", { doc: result.summary.docRef, count: result.sections.length })
}

function renderExpanded(context: ToolCardContext) {
  const result = sectionsResult(context)
  if (!result) return null

  const href = docHref(result.summary.docRef)

  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        {href ? (
          <InternalLink href={href}>{result.summary.docRef}</InternalLink>
        ) : (
          <span className="font-mono font-semibold text-gray-900 dark:text-gray-100">{result.summary.docRef}</span>
        )}
        <Badge>{t("tool_sections")}</Badge>
      </div>
      <div className="text-sm font-medium text-gray-900 dark:text-gray-100">{result.summary.title}</div>
      {result.sections.length > 0 ? (
        <ol className="space-y-1 rounded border border-gray-200 bg-white p-2 text-xs dark:border-gray-800 dark:bg-gray-950">
          {result.sections.map((section, index) => (
            <li className="grid grid-cols-[auto_minmax(0,1fr)_auto] items-center gap-2" key={`${section.startOffset}-${index}`}>
              <span className="font-mono text-gray-500 dark:text-gray-400">H{section.level}</span>
              <span className="min-w-0 truncate text-gray-900 dark:text-gray-100" style={{ paddingLeft: `${Math.max(section.level - 1, 0) * 0.75}rem` }}>
                {section.text}
              </span>
              <span className="font-mono text-gray-500 dark:text-gray-400">
                {section.startOffset}-{section.endOffset}
              </span>
            </li>
          ))}
        </ol>
      ) : (
        <div className="rounded border border-gray-200 bg-white p-2 text-xs text-gray-600 dark:border-gray-800 dark:bg-gray-950 dark:text-gray-300">
          {t("tool_no_sections")}
        </div>
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
