import type { ProviderFailover } from "../api/providerAvailability"

export function ProviderFailoverNotice({ failover, className = "" }: { failover?: ProviderFailover | null; className?: string }) {
  if (!failover) return null

  const source = failover.manual_override ? "operator override" : failover.automatic ? "automatic failover" : "provider override"
  const title = [
    failover.reason ? `Reason: ${humanize(failover.reason)}` : null,
    failover.availability_state ? `${failover.original_provider_label}: ${humanize(failover.availability_state)}` : null,
    failover.decided_at ? `Decided ${formatTimestamp(failover.decided_at)}` : null,
    failover.evidence_observed_at ? `Evidence observed ${formatTimestamp(failover.evidence_observed_at)}` : null
  ].filter(Boolean).join(". ")

  return (
    <span
      className={`inline-flex max-w-full items-center gap-1.5 rounded-full bg-amber-50 px-2 py-0.5 text-xs font-medium text-amber-800 ring-1 ring-amber-200 dark:bg-amber-950/50 dark:text-amber-100 dark:ring-amber-800 ${className}`}
      title={title || failover.message}
    >
      <span className="truncate">{failover.message}</span>
      <span className="shrink-0 text-amber-600 dark:text-amber-300">- {source}</span>
    </span>
  )
}

function humanize(value: string) {
  return value.replaceAll("_", " ")
}

function formatTimestamp(value: string): string {
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return value
  return date.toLocaleString()
}
