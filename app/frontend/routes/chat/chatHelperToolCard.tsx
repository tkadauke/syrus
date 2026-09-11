import type { ReactNode } from "react"
import type { ToolCardContext } from "@app/pluginToolCards"
import { Badge, CardShell, displayValue, EmptyState, Row, SectionLabel, StatePill } from "./toolCardUi"

const SUMMARY_CHARS = 88

export function compactSummary(value: string | null, maxChars = SUMMARY_CHARS) {
  if (!value) return null
  const compacted = value.replace(/\s+/g, " ").trim()
  return compacted.length > maxChars ? `${compacted.slice(0, maxChars - 3)}...` : compacted
}

function errorMessage(context: ToolCardContext, fallback: string) {
  return displayValue(context.resultBody) ?? fallback
}

export type CardState<T> =
  | { kind: "success"; data: T }
  | { kind: "error"; message: string }
  | { kind: "malformed" }

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
      <div className="rounded border border-red-200 bg-red-50 px-2 py-1 text-red-700 dark:border-red-900 dark:bg-red-950/40 dark:text-red-200">
        {message}
      </div>
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
    const options = Array.isArray(item.options) ? item.options.flatMap((option) => {
      const label = displayValue(option)
      return label ? [label] : []
    }) : []

    return [{
      key: `${index}-${question}`,
      question,
      options,
      multiple: item.multiple === true
    }]
  })
}

export function QuestionList({ questions }: { questions: AskedQuestion[] }) {
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
                <div className="whitespace-pre-wrap break-words font-medium text-gray-900 dark:text-gray-100">{question.question}</div>
                {question.options.length > 0 ? (
                  <div className="mt-1 flex flex-wrap gap-1">
                    <Badge>{question.multiple ? "multi-select" : "single-select"}</Badge>
                    {question.options.map((option) => <Badge key={option}>{option}</Badge>)}
                  </div>
                ) : (
                  <div className="mt-1"><Badge>free text</Badge></div>
                )}
              </div>
            </div>
          </li>
        ))}
      </ol>
    </div>
  )
}

export function OptionalReason({ reason }: { reason: string | null }) {
  if (!reason) return null
  return <Row label="Reason" value={reason} />
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return Object.prototype.toString.call(value) === "[object Object]"
}
