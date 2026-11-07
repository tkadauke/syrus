// Localized relative-time formatting, shared across the SPA.
//
// Intl.RelativeTimeFormat localizes automatically for the viewer's locale
// ("2 minutes ago" / "vor 2 Minuten"), so relative timestamps read in the same
// language as the rest of the UI. Rendered via the <RelativeTimestamp>
// component (components/RelativeTimestamp.tsx), which pairs it with the exact
// local timestamp in a hover title.
import i18n from "../i18n"

// Maps the active i18n language to a valid BCP 47 locale tag for browser Intl
// APIs. Latin ("la") is not represented in ICU data, so it falls back to "en".
export function intlLocale(): string {
  const lang = i18n.language || "en"
  return lang === "la" ? "en" : lang
}

const RELATIVE_UNITS: Array<[Intl.RelativeTimeFormatUnit, number]> = [
  ["year", 60 * 60 * 24 * 365],
  ["month", 60 * 60 * 24 * 30],
  ["week", 60 * 60 * 24 * 7],
  ["day", 60 * 60 * 24],
  ["hour", 60 * 60],
  ["minute", 60],
  ["second", 1]
]

// Short, locale-formatted UTC offset for the viewer's timezone (e.g. "GMT-4").
// Used to disambiguate dense local-time displays -- like TimeAxis's tick
// labels -- where there's no single timestamp to sanity-check via hover,
// unlike RelativeTimestamp's exact-time title.
export function timezoneOffsetLabel(): string {
  const parts = new Intl.DateTimeFormat(intlLocale(), { timeZoneName: "shortOffset" }).formatToParts(new Date())
  return parts.find((part) => part.type === "timeZoneName")?.value ?? ""
}

export function validTimeZone(timeZone: string | null | undefined, fallback = "UTC"): string {
  if (!timeZone) return fallback
  try {
    new Intl.DateTimeFormat("en", { timeZone }).format()
    return timeZone
  } catch {
    return fallback
  }
}

export function calendarDayKey(date: Date, timeZone: string): string {
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone: validTimeZone(timeZone),
    year: "numeric",
    month: "2-digit",
    day: "2-digit"
  }).formatToParts(date)
  const value = (type: Intl.DateTimeFormatPartTypes) => parts.find((part) => part.type === type)?.value || ""
  return `${value("year")}-${value("month")}-${value("day")}`
}

function calendarDayDelta(date: Date, now: Date, timeZone: string): number {
  const [year, month, day] = calendarDayKey(date, timeZone).split("-").map(Number)
  const [nowYear, nowMonth, nowDay] = calendarDayKey(now, timeZone).split("-").map(Number)
  return Math.round((Date.UTC(year, month - 1, day) - Date.UTC(nowYear, nowMonth - 1, nowDay)) / (24 * 60 * 60 * 1000))
}

export function formatRelativeDate(date: Date, now = Date.now(), timeZone = Intl.DateTimeFormat().resolvedOptions().timeZone): string {
  const seconds = Math.round((date.getTime() - now) / 1000)
  const absSeconds = Math.abs(seconds)
  const dayDelta = calendarDayDelta(date, new Date(now), validTimeZone(timeZone))
  if (absSeconds >= 20 * 60 * 60 && Math.abs(dayDelta) <= 1) {
    return new Intl.RelativeTimeFormat(intlLocale(), { numeric: "auto" }).format(dayDelta, "day")
  }
  const [unit, divisor] = RELATIVE_UNITS.find(([, unitSeconds]) => absSeconds >= unitSeconds) || ["second", 1]
  const value = Math.round(seconds / divisor)

  return new Intl.RelativeTimeFormat(intlLocale(), { numeric: "auto" }).format(value, unit)
}
