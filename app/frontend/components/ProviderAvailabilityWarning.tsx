import type { ProviderAvailability } from "../api/providerAvailability"

export function ProviderAvailabilityWarning({ availability, className = "" }: { availability?: ProviderAvailability | null; className?: string }) {
  if (!availability?.usage_exhausted && availability?.state !== "rate_limited" && availability?.state !== "auth_error") return null

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

function warningLabel(availability: NonNullable<ProviderAvailability>): string {
  const base = availability.message || `${availability.label || availability.provider} usage limit reached. This item uses ${availability.label || availability.provider} until usage resets.`
  const evidence = availability.evidence?.current || availability.usage?.evidence
  if (!evidence) return base

  const parts = [
    base,
    `Evidence: ${evidence.status} from ${evidence.source}`,
    evidence.observed_at ? `observed ${formatTimestamp(evidence.observed_at)}` : null,
    scopeLabel(evidence),
    evidence.http_status ? `HTTP ${evidence.http_status}` : null,
  ].filter(Boolean)

  return parts.join(". ")
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
