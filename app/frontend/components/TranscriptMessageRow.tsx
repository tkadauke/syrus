import type { ReactNode } from "react"
import { AnsiText } from "./AnsiText"
import { Markdown } from "../lib/Markdown"

type TranscriptMessageTone = "assistant" | "system" | "tool" | "log"

type TranscriptMessageRowProps = {
  chunk: string
  kind: string | null | undefined
  label: string
  sequence: number
}

const kindTone: Record<string, TranscriptMessageTone> = {
  assistant_text: "assistant",
  system: "system",
  tool_call: "tool",
  rate_limited: "system"
}

const labelToneClasses: Record<TranscriptMessageTone, string> = {
  assistant: "border-gray-200 bg-white text-gray-600 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-300",
  system: "border-amber-200 bg-amber-50 text-amber-800 dark:border-amber-800/70 dark:bg-amber-950/30 dark:text-amber-200",
  tool: "border-cyan-200 bg-cyan-50 text-cyan-800 dark:border-cyan-800/70 dark:bg-cyan-950/30 dark:text-cyan-200",
  log: "border-gray-200 bg-gray-50 text-gray-600 dark:border-gray-700 dark:bg-gray-900/70 dark:text-gray-300"
}

const surfaceClasses: Record<TranscriptMessageTone, string> = {
  assistant: "border-gray-200 bg-white px-4 py-3 text-gray-800 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-100",
  system: "border-amber-200 bg-amber-50 px-3 py-2 text-amber-950 dark:border-amber-800/70 dark:bg-amber-950/30 dark:text-amber-100",
  tool: "border-gray-200 bg-gray-950 px-3 py-2 font-mono text-gray-100 dark:border-gray-700 dark:bg-black",
  log: "border-gray-200 bg-gray-50 px-3 py-2 font-mono text-gray-800 dark:border-gray-700 dark:bg-gray-950 dark:text-gray-100"
}

const codeOutput = (chunk: string) => (
  <pre className="min-w-0 max-w-full whitespace-pre-wrap break-words text-xs leading-relaxed [overflow-wrap:anywhere]">
    <AnsiText text={chunk} />
  </pre>
)

const contentRenderers: Record<TranscriptMessageTone, (chunk: string) => ReactNode> = {
  assistant: (chunk) => <Markdown className="break-words text-sm [overflow-wrap:anywhere]" text={chunk} />,
  system: codeOutput,
  tool: codeOutput,
  log: codeOutput
}

export function TranscriptMessageRow({ chunk, kind, label, sequence }: TranscriptMessageRowProps) {
  const tone = kindTone[kind || ""] || "log"

  return (
    <li className="min-w-0 px-3 py-3 text-sm text-text-primary" data-testid={`run-transcript-log-${tone}`}>
      <div className="flex min-w-0 flex-col gap-2 sm:grid sm:grid-cols-[6rem_minmax(0,1fr)] sm:items-start">
        <div className="min-w-0">
          <span className={`inline-flex max-w-full items-center rounded-full border px-2 py-0.5 text-[0.6875rem] font-medium uppercase ${labelToneClasses[tone]}`}>
            <span className="min-w-0 truncate">{label || `#${sequence}`}</span>
          </span>
        </div>
        <div className={`min-w-0 max-w-full overflow-hidden rounded border leading-relaxed shadow-sm ${surfaceClasses[tone]}`}>
          {contentRenderers[tone](chunk)}
        </div>
      </div>
    </li>
  )
}
