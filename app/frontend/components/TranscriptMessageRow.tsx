import { ChatCommandOutputSurface, SharedMessageRenderer } from "../routes/chat/MessageCards"

type TranscriptMessageRowProps = {
  chunk: string
  kind: string | null | undefined
  label: string
  sequence: number
}

export function TranscriptMessageRow({ chunk, kind, label, sequence }: TranscriptMessageRowProps) {
  const displayLabel = label || `#${sequence}`
  return (
    <SharedMessageRenderer as="li" compact copyText={chunk} readOnly testId="run-transcript-log-compact">
      <div data-kind={kind || "log"}>
        <ChatCommandOutputSurface command={displayLabel} compact emptyLabel="" output={chunk} testId="run-transcript-compact-output" />
      </div>
    </SharedMessageRenderer>
  )
}
