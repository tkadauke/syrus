// Run-transcript log helpers extracted from JobDetail.tsx.
//
// Coalesce a run's streamed log chunks by source, derive a per-log source
// key, detect command markers, decide when consecutive logs merge, join
// chunks, and the transcript scroll-position helpers. Pure over the run-
// artifact log type; lifted out of the 3k-line JobDetail.tsx.
import type { fetchJobRunArtifacts } from "../../api/jobs"

const RUN_TRANSCRIPT_BOTTOM_THRESHOLD_PX = 24

export type TranscriptLog = NonNullable<Awaited<ReturnType<typeof fetchJobRunArtifacts>>["logs"]>[number]
export type DisplayTranscriptLog = TranscriptLog & { sourceKey: string }

export function coalesceTranscriptLogs(logs: TranscriptLog[]) {
  const displayLogs: DisplayTranscriptLog[] = []
  const sourceByKind = new Map<string, string>()

  for (const log of logs) {
    const displayLog = { ...log, sourceKey: transcriptLogSourceKey(log, sourceByKind) }
    const previous = displayLogs.at(-1)
    if (previous && shouldCoalesceTranscriptLogs(previous, displayLog)) {
      previous.chunk = joinTranscriptChunks(previous.chunk, displayLog.chunk)
      continue
    }

    displayLogs.push(displayLog)
  }

  return displayLogs
}

export function transcriptLogSourceKey(log: TranscriptLog, sourceByKind: Map<string, string>) {
  const kind = log.kind || "log"
  const command = commandMarkerSource(log.chunk)
  if (command) {
    const source = `${kind}:command:${command}`
    sourceByKind.set(kind, source)
    return source
  }

  return sourceByKind.get(kind) || `${kind}:run`
}

export function commandMarkerSource(chunk: string) {
  const firstLine = chunk.split(/\r?\n/, 1)[0]?.trim() || ""
  const marker = firstLine.match(/^\[(prepare|grade|grader:[^\]]+)\](?: \(\d+\/\d+\))? \$ (.+)$/)
  if (!marker) return null

  return `${marker[1]}:${marker[2]}`
}

export function shouldCoalesceTranscriptLogs(previous: DisplayTranscriptLog, next: DisplayTranscriptLog) {
  if (previous.kind !== next.kind) return false
  if (previous.sourceKey !== next.sourceKey) return false
  return !["tool_call", "rate_limited"].includes(previous.kind || "")
}

export function joinTranscriptChunks(previous: string, next: string) {
  if (previous.endsWith("\n") || next.startsWith("\n")) return previous + next
  return `${previous}\n${next}`
}

export function isRunTranscriptAtBottom(element: HTMLElement) {
  return element.scrollHeight - element.scrollTop - element.clientHeight <= RUN_TRANSCRIPT_BOTTOM_THRESHOLD_PX
}

export function scrollRunTranscriptToBottom(element: HTMLElement | null) {
  if (!element) return
  element.scrollTop = element.scrollHeight
}
