import type { ReactNode } from "react"
import type { ToolCardContext } from "@app/pluginToolCards"
import { Badge, CardShell, displayValue, EmptyState, Row, SectionLabel, StatePill } from "./toolCardUi"
import { MarkdownPreview } from "./toolCardMarkdown"
import type { MarkdownLinkHandler } from "../../lib/Markdown"
import i18n from "../../i18n"

const SUMMARY_CHARS = 88
const QUESTION_SLUG_HREF_FALLBACKS = { DOC: "/design_docs/:id" }
const QUESTION_OPTION_CLASS = [
  "inline-flex min-h-11 w-full min-w-0 max-w-full items-center rounded-[var(--radius-pill)]",
  "bg-neutral-surface px-2 py-0.5 text-2xs text-neutral-text ring-1 ring-neutral-border",
  "sm:min-h-0 sm:w-auto"
].join(" ")

export function compactSummary(value: string | null, maxChars = SUMMARY_CHARS) {
  if (!value) return null
  const compacted = value.replace(/\s+/g, " ").trim()
  return compacted.length > maxChars ? `${compacted.slice(0, maxChars - 3)}...` : compacted
}

function errorMessage(context: ToolCardContext, fallback: string) {
  return displayValue(context.resultBody) ?? fallback
}

export type CardState<T> = { kind: "success"; data: T } | { kind: "error"; message: string } | { kind: "malformed" }

export function successOrError<T>(context: ToolCardContext, fallbackError: string, parse: (parsed: Record<string, unknown>) => T | null): CardState<T> {
  if (context.resultError) return { kind: "error", message: errorMessage(context, fallbackError) }
  if (!isPlainObject(context.parsedResult)) return { kind: "malformed" }

  const data = parse(context.parsedResult)
  return data ? { kind: "success", data } : { kind: "malformed" }
}

export function StatusCard({ title, status, children }: { title: string; status?: string | null; children?: ReactNode }) {
  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <span className="font-medium text-gray-900 dark:text-gray-100">{title}</span>
        {status ? <StatePill state={status} /> : null}
      </div>
      {children}
    </CardShell>
  )
}

export function ErrorCard({ title, message }: { title: string; message: string }) {
  return (
    <StatusCard title={title} status="failed">
      <div className="rounded border border-red-200 bg-red-50 px-2 py-1 text-red-700 dark:border-red-900 dark:bg-red-950/40 dark:text-red-200">{message}</div>
    </StatusCard>
  )
}

export function MalformedCard({ title, children }: { title: string; children?: ReactNode }) {
  return (
    <StatusCard title={title} status="unknown">
      {children ?? <EmptyState>Unexpected tool response.</EmptyState>}
    </StatusCard>
  )
}

export type AskedQuestion = {
  key: string
  question: string
  options: string[]
  multiple: boolean
}

export function questionsFromInput(input: Record<string, unknown> | undefined): AskedQuestion[] {
  const questions = input?.questions
  if (!Array.isArray(questions)) return []

  return questions.flatMap((item, index): AskedQuestion[] => {
    if (!isPlainObject(item)) return []
    const question = displayValue(item.question)
    if (!question) return []
    const options = Array.isArray(item.options)
      ? item.options.flatMap((option) => {
          const label = displayValue(option)
          return label ? [label] : []
        })
      : []

    return [
      {
        key: `${index}-${question}`,
        question,
        options,
        multiple: item.multiple === true
      }
    ]
  })
}

export function QuestionList({ questions, onLinkClick }: { questions: AskedQuestion[]; onLinkClick?: MarkdownLinkHandler }) {
  if (questions.length === 0) return <EmptyState>Question text was not included with this transcript entry.</EmptyState>

  return (
    <div className="space-y-2">
      <SectionLabel>Questions</SectionLabel>
      <ol className="space-y-2">
        {questions.map((question, index) => (
          <li className="rounded border border-gray-200 bg-white p-2 dark:border-gray-800 dark:bg-gray-950" key={question.key}>
            <div className="flex min-w-0 gap-2">
              <span className="shrink-0 font-mono text-2xs text-gray-500 dark:text-gray-400">#{index + 1}</span>
              <div className="min-w-0 flex-1">
                <div className="font-medium text-gray-900 dark:text-gray-100">
                  <MarkdownPreview
                    linkifySlugs
                    linkifyUrls
                    maxChars={500}
                    maxLines={4}
                    onLinkClick={onLinkClick}
                    slugHrefFallbacks={QUESTION_SLUG_HREF_FALLBACKS}
                    text={question.question}
                  />
                </div>
                {question.options.length > 0 ? (
                  <div className="mt-1 flex flex-wrap gap-1">
                    <Badge>{question.multiple ? "multi-select" : "single-select"}</Badge>
                    {question.options.map((option) => (
                      <div className={QUESTION_OPTION_CLASS} data-testid="question-option" key={option}>
                        <MarkdownPreview
                          linkifySlugs
                          linkifyUrls
                          maxChars={240}
                          maxLines={3}
                          onLinkClick={onLinkClick}
                          slugHrefFallbacks={QUESTION_SLUG_HREF_FALLBACKS}
                          text={option}
                        />
                      </div>
                    ))}
                  </div>
                ) : (
                  <div className="mt-1">
                    <Badge>free text</Badge>
                  </div>
                )}
              </div>
            </div>
          </li>
        ))}
      </ol>
    </div>
  )
}

export function OptionalReason({ reason, onLinkClick, title }: { reason: string | null; onLinkClick?: MarkdownLinkHandler; title?: string }) {
  if (!reason) return null
  return (
    <div className="min-w-0 sm:col-span-2">
      <MarkdownPreview
        linkifySlugs
        linkifyUrls
        maxChars={500}
        maxLines={4}
        onLinkClick={onLinkClick}
        text={reason}
        title={title || i18n.t("chat:tool_card_reason")}
      />
    </div>
  )
}

function detailValue(value: unknown) {
  const displayed = displayValue(value)
  if (displayed) return displayed
  if (value == null) return "—"
  try {
    return JSON.stringify(value)
  } catch {
    return String(value)
  }
}

export function StructuredDetails({ details, emptyLabel, title }: { details: Record<string, unknown> | null; emptyLabel: string; title: string }) {
  if (!details || Object.keys(details).length === 0) return <EmptyState>{emptyLabel}</EmptyState>

  return (
    <details className="min-w-0 rounded border border-border bg-surface px-2 py-1 sm:col-span-2">
      <summary className="cursor-pointer break-words text-2xs font-semibold uppercase text-text-muted [overflow-wrap:anywhere]">{title}</summary>
      <dl className="mt-2 grid min-w-0 gap-2 sm:grid-cols-2">
        {Object.entries(details).map(([key, value]) => (
          <div className="min-w-0" key={key}>
            <dt className="break-words text-2xs font-semibold text-text-muted [overflow-wrap:anywhere]">{key}</dt>
            <dd className="break-words font-mono text-xs text-text-primary [overflow-wrap:anywhere]">{detailValue(value)}</dd>
          </div>
        ))}
      </dl>
    </details>
  )
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return Object.prototype.toString.call(value) === "[object Object]"
}
