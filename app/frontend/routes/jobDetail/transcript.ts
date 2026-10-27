// Run-transcript log helpers extracted from JobDetail.tsx.
//
// Coalesce a run's streamed log chunks by source, derive a per-log source
// key, detect command markers, decide when consecutive logs merge, join
// chunks, and the transcript scroll-position helpers. Pure over the run-
// artifact log type; lifted out of the 3k-line JobDetail.tsx.
import type { fetchJobRunArtifacts } from "../../api/jobs"

const RUN_TRANSCRIPT_BOTTOM_THRESHOLD_PX = 24

export type TranscriptLog = NonNullable<Awaited<ReturnType<typeof fetchJobRunArtifacts>>["logs"]>[number]
export function isRunTranscriptAtBottom(element: HTMLElement) {
  return element.scrollHeight - element.scrollTop - element.clientHeight <= RUN_TRANSCRIPT_BOTTOM_THRESHOLD_PX
}

export function scrollRunTranscriptToBottom(element: HTMLElement | null) {
  if (!element) return
  element.scrollTop = element.scrollHeight
}
