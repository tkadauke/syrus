import type { ReactNode } from "react"
import { useTimeZones } from "../contexts/TimeZoneContext"
import { useT } from "../hooks/useT"
import { intlLocale, validTimeZone } from "../lib/relativeTime"

export function AbsoluteTimestamp({ value, className, fallback = "-" }: { value: string | null | undefined; className?: string; fallback?: ReactNode }) {
  const { user, server } = useTimeZones()
  const { t } = useT("common")
  if (!value) return <>{fallback}</>
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return <>{fallback}</>

  const format = (timeZone: string) =>
    new Intl.DateTimeFormat(intlLocale(), {
      year: "numeric",
      month: "short",
      day: "numeric",
      hour: "numeric",
      minute: "2-digit",
      timeZone: validTimeZone(timeZone),
      timeZoneName: "short"
    }).format(date)
  const sameZone = user === server

  return (
    <time className={className} dateTime={date.toISOString()} title={date.toISOString()}>
      {sameZone ? format(user) : `${t("absolute_time.user", { value: format(user) })} · ${t("absolute_time.server", { value: format(server) })}`}
    </time>
  )
}
