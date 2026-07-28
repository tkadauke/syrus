import type { ReactNode } from "react"
import { formatRelativeDate, intlLocale } from "../lib/relativeTime"

// The canonical way to show a timestamp in the SPA: a localized relative time
// ("2 minutes ago"), with the exact date+time in the viewer's locale on hover.
// Renders `fallback` (default "-") for a missing or unparseable value; pass a
// `fallback` for context-specific empty text (e.g. "not started", "never").
export function RelativeTimestamp({
  value,
  className,
  fallback = "-"
}: {
  value: string | null | undefined
  className?: string
  fallback?: ReactNode
}) {
  if (!value) return <>{fallback}</>

  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return <>{fallback}</>

  const exact = new Intl.DateTimeFormat(intlLocale(), { dateStyle: "medium", timeStyle: "short" }).format(date)

  return (
    <time className={className} dateTime={value} title={exact}>
      {formatRelativeDate(date)}
    </time>
  )
}
