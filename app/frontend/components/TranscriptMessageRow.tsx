import { ChatAssistantMarkdownSurface, SharedMessageRenderer, SystemMessage } from "../routes/chat/MessageCards"

type TranscriptMessageRowProps = {
  chunk: string
  kind: string | null | undefined
  label: string
  sequence: number
}

export function TranscriptMessageRow({ chunk, kind, label, sequence }: TranscriptMessageRowProps) {
  const displayLabel = label || `#${sequence}`

  if (kind === "assistant_text" || kind === "assistant") {
    return (
      <SharedMessageRenderer as="li" readOnly testId="run-transcript-log-assistant">
        <ChatAssistantMarkdownSurface text={chunk} />
      </SharedMessageRenderer>
    )
  }

  return (
    <SharedMessageRenderer as="li" readOnly testId="run-transcript-log-system">
      <SystemMessage item={{ tone: "neutral", label: displayLabel, body: chunk, prominent: true }} prefix="" />
    </SharedMessageRenderer>
  )
}
