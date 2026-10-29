import { ChatCommandOutputSurface } from "../routes/chat/MessageCards"

type TranscriptMessageRowProps = {
  chunk: string
  kind: string | null | undefined
  label: string
  sequence: number
}

export function TranscriptMessageRow({ chunk, kind, label, sequence }: TranscriptMessageRowProps) {
  const displayLabel = label || `#${sequence}`
  return (
    <li className="min-w-0" data-kind={kind || "log"} data-testid="run-transcript-log-compact">
      <ChatCommandOutputSurface command={displayLabel} compact emptyLabel="" output={chunk} testId="run-transcript-compact-output" />
    </li>
  )
}
