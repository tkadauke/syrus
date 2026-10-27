import type { ProviderAvailability, ProviderFailover, ProviderMismatch } from "../api/providerAvailability"
import type { TFunction } from "i18next"
import { useT } from "../hooks/useT"
import { TonePill } from "./StatusPill"

export function ProviderAvailabilityWarning({ availability, className = "" }: { availability?: ProviderAvailability | null; className?: string }) {
  const { t } = useT("common")
  if (!availability) return null

  const lowUsage = providerUsageLow(availability)
  if (
    !availability.usage_exhausted &&
    !lowUsage &&
    availability.state !== "rate_limited" &&
    availability.state !== "auth_error" &&
    availability.state !== "open"
  )
    return null

  const label = warningLabel(availability, lowUsage, t)
  const tone = availability.usage_exhausted || availability.state === "auth_error" ? "text-red-600 dark:text-red-400" : "text-amber-600 dark:text-amber-400"

  return (
    <span aria-label={label} className={`inline-flex shrink-0 ${tone} ${className}`} role="img" title={label}>
      <svg
        aria-hidden="true"
        className="h-4 w-4"
        fill="none"
        stroke="currentColor"
        strokeLinecap="round"
        strokeLinejoin="round"
        strokeWidth="2"
        viewBox="0 0 24 24"
      >
        <path d="M10.3 3.9 1.8 18a2 2 0 0 0 1.7 3h17a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0Z" />
        <path d="M12 9v4" />
        <path d="M12 17h.01" />
      </svg>
    </span>
  )
}

export function ProviderFailoverNotice({ failover, className = "" }: { failover?: ProviderFailover | null; className?: string }) {
  const { t } = useT("common")
  if (!failover) return null

  const copy = providerFailoverCopy(failover, t)
  const label = failoverLabel(failover, copy, t)

  return (
    <span
      className={`inline-flex max-w-full items-center rounded border border-amber-200 bg-amber-50 px-2 py-0.5 text-xs font-medium text-amber-800 dark:border-amber-900 dark:bg-amber-950/40 dark:text-amber-200 ${className}`}
      title={label}
    >
      {copy}
    </span>
  )
}

// Tooltip text for a provider pill that stands in for a full ProviderFailoverNotice:
// same detail (reason, retry/reset timing, evidence), collapsed into a single `title`
// instead of a separate pill next to the provider's own pill.
export function providerFailoverTooltip(failover: ProviderFailover | null | undefined, t: TFunction<"common">): string | undefined {
  if (!failover) return undefined

  return failoverLabel(failover, providerFailoverCopy(failover, t), t)
}

function providerFailoverCopy(failover: NonNullable<ProviderFailover>, t: TFunction<"common">): string {
  return failover.automatic
    ? t("provider_warning.automatic_failover", { original: failover.original_provider_label, selected: failover.selected_provider_label })
    : t("provider_warning.operator_failover", { original: failover.original_provider_label, selected: failover.selected_provider_label })
}

// Compact alternative to ProviderFailoverNotice for dense list rows (e.g. the
// dashboard jobs table): a single red pill next to the job slug instead of a
// full-sentence banner next to the title. Flags a Job pinned away from what
// its repository would otherwise use, regardless of why (explicit pin,
// automatic failover, etc.) -- see App::DashboardPayload#provider_mismatch_for.
export function ProviderMismatchPill({ mismatch }: { mismatch?: ProviderMismatch | null }) {
  const { t } = useT("common")
  if (!mismatch) return null

  const title = t("provider_warning.mismatch", { jobProvider: mismatch.job_provider_label, repositoryProvider: mismatch.repository_provider_label })

  return (
    <TonePill ariaLabel={title} title={title} tone="red">
      {mismatch.job_provider_label}
    </TonePill>
  )
}

function providerUsageLow(availability?: ProviderAvailability | null): boolean {
  const remaining = availability?.usage?.remaining_percent
  const threshold = availability?.pause_threshold_percent
  return availability?.pause_enabled === true && remaining != null && threshold != null && remaining < threshold
}

function warningLabel(availability: NonNullable<ProviderAvailability>, lowUsage: boolean, t: TFunction<"common">): string {
  const providerLabel = availability.label || availability.provider
  const base = lowUsage
    ? t("provider_warning.usage_low", {
        provider: providerLabel,
        remaining: Math.round(availability.usage?.remaining_percent ?? 0),
        threshold: availability.pause_threshold_percent
      })
    : availability.message || t("provider_warning.usage_reached", { provider: providerLabel })
  const evidence = availability.evidence?.current || availability.usage?.evidence
  const timing = [
    availability.retry_after ? t("provider_warning.retry_after", { time: formatTimestamp(availability.retry_after) }) : null,
    availability.usage?.windows?.five_hour?.reset_at
      ? t("provider_warning.five_hour_reset", { time: formatTimestamp(availability.usage.windows.five_hour.reset_at) })
      : null,
    availability.usage?.windows?.weekly?.reset_at
      ? t("provider_warning.weekly_reset", { time: formatTimestamp(availability.usage.windows.weekly.reset_at) })
      : null
  ].filter(Boolean)
  if (!evidence) return [base, ...timing].join(". ")

  const parts = [
    base,
    t("provider_warning.evidence", { status: evidence.status, source: evidence.source }),
    evidence.observed_at ? t("provider_warning.observed", { time: formatTimestamp(evidence.observed_at) }) : null,
    scopeLabel(evidence, t),
    evidence.http_status ? `HTTP ${evidence.http_status}` : null,
    ...timing
  ].filter(Boolean)

  return parts.join(". ")
}

function failoverLabel(failover: NonNullable<ProviderFailover>, base: string, t: TFunction<"common">): string {
  const unavailable = failover.unavailable
  if (!unavailable) return base

  return [
    base,
    unavailable.state ? t("provider_warning.state", { provider: unavailable.label || failover.original_provider_label, state: unavailable.state }) : null,
    unavailable.reason ? t("provider_warning.reason", { reason: unavailable.reason }) : null,
    unavailable.retry_after ? t("provider_warning.retry_after", { time: formatTimestamp(unavailable.retry_after) }) : null,
    unavailable.reset_at ? t("provider_warning.reset", { time: formatTimestamp(unavailable.reset_at) }) : null,
    unavailable.evidence_source || unavailable.evidence_status
      ? t("provider_warning.evidence", { status: unavailable.evidence_status || "—", source: unavailable.evidence_source || "—" })
      : null,
    unavailable.observed_at ? t("provider_warning.observed", { time: formatTimestamp(unavailable.observed_at) }) : null,
    failover.decided_at ? t("provider_warning.decided", { time: formatTimestamp(failover.decided_at) }) : null
  ]
    .filter(Boolean)
    .join(". ")
}

function scopeLabel(evidence: NonNullable<NonNullable<ProviderAvailability>["evidence"]>["current"], t: TFunction<"common">): string | null {
  if (!evidence) return null

  const scope = [
    evidence.provider,
    evidence.account_id ? t("provider_warning.account", { id: evidence.account_id }) : null,
    evidence.model ? t("provider_warning.model", { model: evidence.model }) : null
  ].filter(Boolean)

  return scope.length ? t("provider_warning.scope", { scope: scope.join(" / ") }) : null
}

function formatTimestamp(value: string): string {
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return value
  return date.toLocaleString()
}
