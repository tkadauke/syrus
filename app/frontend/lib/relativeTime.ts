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

export function formatRelativeDate(date: Date, now = Date.now()): string {
  const seconds = Math.round((date.getTime() - now) / 1000)
  const absSeconds = Math.abs(seconds)
  const [unit, divisor] = RELATIVE_UNITS.find(([, unitSeconds]) => absSeconds >= unitSeconds) || ["second", 1]
  const value = Math.round(seconds / divisor)

  return new Intl.RelativeTimeFormat(intlLocale(), { numeric: "auto" }).format(value, unit)
}
