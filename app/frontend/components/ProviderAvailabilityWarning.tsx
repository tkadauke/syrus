import type { ProviderAvailability, ProviderFailover } from "../api/providerAvailability"

export function ProviderAvailabilityWarning({ availability, className = "" }: { availability?: ProviderAvailability | null; className?: string }) {
  if (!availability?.usage_exhausted && availability?.state !== "rate_limited" && availability?.state !== "auth_error" && availability?.state !== "open") return null

  const label = warningLabel(availability)
  const tone = availability.usage_exhausted || availability.state === "auth_error" ? "text-red-600 dark:text-red-400" : "text-amber-600 dark:text-amber-400"

  return (
    <span aria-label={label} className={`inline-flex shrink-0 ${tone} ${className}`} role="img" title={label}>
      <svg aria-hidden="true" className="h-4 w-4" fill="none" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="2" viewBox="0 0 24 24">
        <path d="M10.3 3.9 1.8 18a2 2 0 0 0 1.7 3h17a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0Z" />
        <path d="M12 9v4" />
        <path d="M12 17h.01" />
      </svg>
    </span>
  )
}

export function ProviderFailoverNotice({ failover, className = "" }: { failover?: ProviderFailover | null; className?: string }) {
  if (!failover) return null

  const copy = failover.automatic
    ? `${failover.original_provider_label} unavailable; running this workflow with ${failover.selected_provider_label}.`
    : `Operator selected ${failover.selected_provider_label} for this workflow instead of ${failover.original_provider_label}.`
  const label = failoverLabel(failover, copy)

  return (
    <span className={`inline-flex max-w-full items-center rounded border border-amber-200 bg-amber-50 px-2 py-0.5 text-xs font-medium text-amber-800 dark:border-amber-900 dark:bg-amber-950/40 dark:text-amber-200 ${className}`} title={label}>
      {copy}
    </span>
  )
}

function warningLabel(availability: NonNullable<ProviderAvailability>): string {
  const base = availability.message || `${availability.label || availability.provider} usage limit reached. This item uses ${availability.label || availability.provider} until usage resets.`
  const evidence = availability.evidence?.current || availability.usage?.evidence
  const timing = [
    availability.retry_after ? `retry after ${formatTimestamp(availability.retry_after)}` : null,
    availability.usage?.windows?.five_hour?.reset_at ? `5h reset ${formatTimestamp(availability.usage.windows.five_hour.reset_at)}` : null,
    availability.usage?.windows?.weekly?.reset_at ? `weekly reset ${formatTimestamp(availability.usage.windows.weekly.reset_at)}` : null,
  ].filter(Boolean)
  if (!evidence) return [base, ...timing].join(". ")

  const parts = [
    base,
    `Evidence: ${evidence.status} from ${evidence.source}`,
    evidence.observed_at ? `observed ${formatTimestamp(evidence.observed_at)}` : null,
    scopeLabel(evidence),
    evidence.http_status ? `HTTP ${evidence.http_status}` : null,
    ...timing,
  ].filter(Boolean)

  return parts.join(". ")
}

function failoverLabel(failover: NonNullable<ProviderFailover>, base: string): string {
  const unavailable = failover.unavailable
  if (!unavailable) return base

  return [
    base,
    unavailable.state ? `${unavailable.label || failover.original_provider_label} state: ${unavailable.state}` : null,
    unavailable.reason ? `Reason: ${unavailable.reason}` : null,
    unavailable.retry_after ? `Retry after ${formatTimestamp(unavailable.retry_after)}` : null,
    unavailable.reset_at ? `Reset ${formatTimestamp(unavailable.reset_at)}` : null,
    unavailable.evidence_source || unavailable.evidence_status ? `Evidence: ${[unavailable.evidence_status, unavailable.evidence_source].filter(Boolean).join(" from ")}` : null,
    unavailable.observed_at ? `Observed ${formatTimestamp(unavailable.observed_at)}` : null,
    failover.decided_at ? `Decided ${formatTimestamp(failover.decided_at)}` : null,
  ].filter(Boolean).join(". ")
}

function scopeLabel(evidence: NonNullable<NonNullable<ProviderAvailability>["evidence"]>["current"]): string | null {
  if (!evidence) return null

  const scope = [
    evidence.provider,
    evidence.account_id ? `account ${evidence.account_id}` : null,
    evidence.model ? `model ${evidence.model}` : null,
  ].filter(Boolean)

  return scope.length ? `scope ${scope.join(" / ")}` : null
}

function formatTimestamp(value: string): string {
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return value
  return date.toLocaleString()
}
