import { useT } from "../hooks/useT"
import type { StartBlockedDetails } from "../types/startBlocked"
import { TonePill } from "./StatusPill"

type StartBlockedReason =
  | "dependency_failed"
  | "stack_dependencies_not_ready"
  | "stack_fan_in_base_unavailable"
  | "job_not_ready_for_execution"
  | "main_branch_broken"
  | "urgent_job_active"
  | "provider_availability"

const TONES: Record<StartBlockedReason, "amber" | "red" | "gray"> = {
  dependency_failed: "red",
  stack_dependencies_not_ready: "amber",
  stack_fan_in_base_unavailable: "amber",
  job_not_ready_for_execution: "amber",
  main_branch_broken: "red",
  urgent_job_active: "gray",
  provider_availability: "amber"
}

const THROTTLE_URGENCY_THRESHOLD_MS = 30 * 60 * 1000

export function StartBlockedReasonPill({
  reason,
  details,
  startBlockedAt,
  nextCheckAt,
  count,
}: {
  reason: string
  details?: StartBlockedDetails | null
  startBlockedAt?: string | null
  nextCheckAt?: string | null
  count?: number | null
}) {
  const { t } = useT()
  const baseTone = TONES[reason as StartBlockedReason] ?? "amber"
  const isStale = startBlockedAt
    ? Date.now() - new Date(startBlockedAt).getTime() > THROTTLE_URGENCY_THRESHOLD_MS
    : false
  const tone = baseTone === "gray" && isStale ? "amber" : baseTone
  const title = startBlockedTitle(reason, details, nextCheckAt ?? null, count ?? null, t)

  return (
    <TonePill
      tone={tone}
      title={title}
    >
      {t(`common:start_blocked_reasons.${reason}`, { defaultValue: reason })}
    </TonePill>
  )
}

function startBlockedTitle(
  reason: string,
  details: StartBlockedDetails | null | undefined,
  nextCheckAt: string | null,
  count: number | null,
  t: ReturnType<typeof useT>["t"]
) {
  const lines = [t(`common:start_blocked_reason_tooltips.${reason}`, { defaultValue: "" })].filter(Boolean)
  if (details?.message) lines.push(details.message)
  if (details?.dependencies?.length) {
    lines.push(`Dependencies: ${details.dependencies.map((dependency) => dependency.slug || (dependency.job_id ? `JOB-${dependency.job_id}` : null)).filter(Boolean).join(", ")}`)
  }
  if (details?.action) lines.push(details.action)
  if (nextCheckAt) {
    const diffMs = new Date(nextCheckAt).getTime() - Date.now()
    if (diffMs > 0) {
      const diffMin = Math.ceil(diffMs / 60_000)
      lines.push(`Next retry in ${diffMin} ${diffMin === 1 ? "minute" : "minutes"}`)
    }
  }
  if (count != null && count > 1) {
    lines.push(`Refused ${count} times`)
  }
  return lines.join("\n")
}
