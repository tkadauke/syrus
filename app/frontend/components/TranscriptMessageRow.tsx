import { ChatAssistantMarkdownSurface, ChatCommandOutputSurface, SystemMessage } from "../routes/chat/MessageCards"

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

export function TranscriptMessageRow({ chunk, kind, label, sequence }: TranscriptMessageRowProps) {
  const tone = kindTone[kind || ""] || "log"
  const displayLabel = label || `#${sequence}`

  if (tone === "assistant") {
    return (
      <li className="min-w-0 px-3 py-2 text-sm text-text-primary" data-testid="run-transcript-log-assistant">
        <article className="min-w-0 space-y-1">
          <div className="px-1 text-2xs font-medium uppercase text-text-secondary">{displayLabel}</div>
          <ChatAssistantMarkdownSurface compact text={chunk} />
        </article>
      </li>
    )
  }

  if (tone === "system") {
    return (
      <li className="min-w-0 px-3 py-2 text-sm text-text-primary" data-testid="run-transcript-log-system">
        <SystemMessage item={{ tone: "neutral", label: displayLabel, body: chunk, prominent: true }} prefix="" />
      </li>
    )
  }

  return (
    <li className="min-w-0 px-3 py-2 text-sm text-text-primary" data-testid={`run-transcript-log-${tone}`}>
      <ChatCommandOutputSurface command={displayLabel} compact emptyLabel="" output={chunk} testId={`run-transcript-${tone}-output`} />
    </li>
  )
}
