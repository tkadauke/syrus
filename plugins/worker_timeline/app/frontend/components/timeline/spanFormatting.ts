import type { WorkerTimelineBlockedInfo } from "../../api/workerTimeline"

// Duration and blocked-reason tooltip text, shared by the macro (Workflow
// span) and micro (Run/Step span) chart views.
export function formatDuration(startedAt: string, finishedAt: string | null): string {
  const start = new Date(startedAt).getTime()
  const end = finishedAt ? new Date(finishedAt).getTime() : Date.now()
  const totalSeconds = Math.max(0, Math.round((end - start) / 1000))
  const hours = Math.floor(totalSeconds / 3600)
  const minutes = Math.floor((totalSeconds % 3600) / 60)
  const seconds = totalSeconds % 60
  const parts = []
  if (hours) parts.push(`${hours}h`)
  if (hours || minutes) parts.push(`${minutes}m`)
  parts.push(`${seconds}s`)

  const label = parts.join(" ")
  return finishedAt ? label : `${label}+ (running)`
}

export function blockedMessage(
  blocked: WorkerTimelineBlockedInfo,
  t: (key: string, options?: Record<string, unknown>) => string
): string {
  if (!blocked.available) {
    return blocked.historical ? t("no_historical_blocker_data") : t("no_blocker_data")
  }

  return t("blocked_reason_line", { reason: blocked.blocked_reason })
}
