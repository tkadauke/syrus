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
  | "workflow_admission_budget"
  | "provider_availability"

const TONES: Record<StartBlockedReason, "amber" | "red" | "gray"> = {
  dependency_failed: "red",
  stack_dependencies_not_ready: "amber",
  stack_fan_in_base_unavailable: "amber",
  job_not_ready_for_execution: "amber",
  main_branch_broken: "red",
  urgent_job_active: "gray",
  workflow_admission_budget: "amber",
  provider_availability: "amber"
}

const THROTTLE_URGENCY_THRESHOLD_MS = 30 * 60 * 1000
const ADMISSION_REASON_COPY: Record<string, string> = {
  worker_host_pressure_high: "Worker host pressure is high.",
  worker_memory_exhausted: "Worker memory is exhausted.",
  worker_disk_exhausted: "Worker disk space is exhausted.",
  predicted_budget_pressure_high: "Predicted workflow cost would exceed the worker budget.",
  pending_high_cost_work: "High-cost work is already pending.",
  repository_concurrency_budget_exhausted: "This repository already has enough active workflow work.",
  conservative_default_estimate: "Syrus is using a conservative default estimate.",
  bootstrap_missing_profiles: "Syrus is still building resource profiles for this workflow.",
  minimum_progress_floor: "Syrus is preserving worker capacity for minimum progress.",
  within_budget: "Current worker budget can admit this workflow.",
  non_admitted_queue: "This workflow queue is not controlled by admission budgeting."
}

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
  const admissionBudget = reason === "workflow_admission_budget"
  const lines = [t(`common:start_blocked_reason_tooltips.${reason}`, { defaultValue: "" })].filter(Boolean)
  if (details?.message) lines.push(details.message)
  if (details?.dependencies?.length) {
    lines.push(`Dependencies: ${details.dependencies.map((dependency) => dependency.slug || (dependency.job_id ? `JOB-${dependency.job_id}` : null)).filter(Boolean).join(", ")}`)
  }
  if (admissionBudget) {
    lines.push(...workflowAdmissionDetails(details, nextCheckAt))
  } else if (details?.action && humanReadableAction(details.action)) {
    lines.push(details.action)
  }
  if (nextCheckAt && !admissionBudget) {
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

function workflowAdmissionDetails(details: StartBlockedDetails | null | undefined, nextCheckAt: string | null) {
  const lines: string[] = []
  const delayUntil = details?.delay_until || nextCheckAt
  if (delayUntil) {
    lines.push(`${details?.delay_until ? "Delayed until" : "Will check again at"} ${formatTooltipTime(delayUntil)}`)
  }

  const reason = admissionReasonLine(details)
  if (reason) lines.push(reason)
  if (usesConservativeDefaultEstimate(details) && reason !== ADMISSION_REASON_COPY.conservative_default_estimate) {
    lines.push(ADMISSION_REASON_COPY.conservative_default_estimate)
  }

  const pressure = admissionPressureLine(details)
  if (pressure) lines.push(pressure)

  return lines
}

function admissionReasonLine(details: StartBlockedDetails | null | undefined) {
  const reason = details?.reason
  if (!reason) {
    if (usesConservativeDefaultEstimate(details)) {
      return ADMISSION_REASON_COPY.conservative_default_estimate
    }
    return null
  }

  if (ADMISSION_REASON_COPY[reason]) return ADMISSION_REASON_COPY[reason]
  if (usesConservativeDefaultEstimate(details)) {
    return ADMISSION_REASON_COPY.conservative_default_estimate
  }
  return `Admission reason: ${humanizeKey(reason)}.`
}

function usesConservativeDefaultEstimate(details: StartBlockedDetails | null | undefined) {
  return details?.details?.decision_basis === "conservative_defaults" ||
    details?.details?.prediction_source === "conservative_defaults" ||
    details?.pressure?.candidate?.predicted_command_cost?.source === "conservative_defaults"
}

function admissionPressureLine(details: StartBlockedDetails | null | undefined) {
  const projected = details?.pressure?.projected
  const candidateCost = details?.pressure?.candidate?.predicted_command_cost
  const duration = candidateCost?.duration_seconds ?? details?.pressure?.candidate?.duration_seconds
  const parts = [
    duration != null ? `estimated ${formatDuration(duration)}` : null,
    projected?.cpu_pressure != null ? `projected CPU ${formatNumber(projected.cpu_pressure)}%` : null,
    projected?.io_pressure != null ? `IO ${formatNumber(projected.io_pressure)}%` : null,
    projected?.memory_used_percent != null ? `memory ${formatNumber(projected.memory_used_percent)}%` : null
  ].filter(Boolean)

  return parts.length ? `Pressure: ${parts.slice(0, 3).join(", ")}` : null
}

function humanReadableAction(action: string) {
  return !/^[a-z0-9_-]+$/.test(action)
}

function humanizeKey(value: string) {
  return value.replace(/[_-]+/g, " ").replace(/\s+/g, " ").trim()
}

function formatTooltipTime(value: string) {
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return "the scheduled retry time"

  return new Intl.DateTimeFormat(undefined, {
    month: "short",
    day: "numeric",
    hour: "numeric",
    minute: "2-digit"
  }).format(date)
}

function formatDuration(seconds: number) {
  if (seconds < 60) return `${Math.round(seconds)}s`
  const minutes = Math.round(seconds / 60)
  if (minutes < 60) return `${minutes}m`
  const hours = Math.floor(minutes / 60)
  const remainingMinutes = minutes % 60
  return remainingMinutes ? `${hours}h ${remainingMinutes}m` : `${hours}h`
}

function formatNumber(value: number) {
  return Number.isInteger(value) ? value.toString() : value.toFixed(1)
}
