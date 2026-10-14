import { ChatAssistantMarkdownSurface, ChatCommandOutputSurface, SharedMessageRenderer, SystemMessage } from "../routes/chat/MessageCards"

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
      <SharedMessageRenderer as="li" readOnly testId="run-transcript-log-assistant">
        <ChatAssistantMarkdownSurface text={chunk} />
      </SharedMessageRenderer>
    )
  }

  if (tone === "system") {
    return (
      <SharedMessageRenderer as="li" readOnly testId="run-transcript-log-system">
        <SystemMessage item={{ tone: "neutral", label: displayLabel, body: chunk, prominent: true }} prefix="" />
      </SharedMessageRenderer>
    )
  }

  return (
    <SharedMessageRenderer as="li" readOnly testId={`run-transcript-log-${tone}`}>
      <ChatCommandOutputSurface command={displayLabel} emptyLabel="" output={chunk} testId={`run-transcript-${tone}-output`} />
    </SharedMessageRenderer>
  )
}
