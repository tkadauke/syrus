// Shared display formatting for the cluster viewer tabs. Kept intentionally
// simple - callers only need a compact, human-readable string, not a
// full duration/units library.
export function formatAge(createdAt: string | null | undefined, now: Date = new Date()): string {
  if (!createdAt) return "-"

  const created = new Date(createdAt)
  if (Number.isNaN(created.getTime())) return "-"

  const seconds = Math.max(0, Math.floor((now.getTime() - created.getTime()) / 1000))
  if (seconds < 60) return `${seconds}s`

  const minutes = Math.floor(seconds / 60)
  if (minutes < 60) return `${minutes}m`

  const hours = Math.floor(minutes / 60)
  if (hours < 24) return `${hours}h`

  const days = Math.floor(hours / 24)
  if (days < 365) return `${days}d`

  return `${Math.floor(days / 365)}y`
}

export function formatMillicores(millicores: number): string {
  if (millicores >= 1000) return `${(millicores / 1000).toFixed(2)} vCPU`
  return `${millicores}m`
}

export function formatBytes(bytes: number): string {
  if (!bytes) return "0 B"
  const units = [ "B", "KB", "MB", "GB", "TB", "PB" ]
  const exponent = Math.min(Math.floor(Math.log(bytes) / Math.log(1024)), units.length - 1)
  const value = bytes / 1024 ** exponent
  return `${value.toFixed(exponent === 0 ? 0 : 1)} ${units[exponent]}`
}

const WEEKDAYS = [ "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" ]

export function explainCronSchedule(schedule: string | null | undefined): string | null {
  if (!schedule) return null

  const expression = schedule.trim().replace(/\s+/g, " ")
  const macro = explainCronMacro(expression)
  if (macro) return macro

  const parts = expression.split(" ")
  if (parts.length !== 5) return null

  const [minute, hour, dayOfMonth, month, dayOfWeek] = parts

  if (minute.startsWith("*/") && hour === "*" && dayOfMonth === "*" && month === "*" && dayOfWeek === "*") {
    const interval = parsePositiveInteger(minute.slice(2))
    return interval && interval <= 59 ? `Every ${pluralize(interval, "minute")}` : null
  }

  if (isInteger(minute) && hour.startsWith("*/") && dayOfMonth === "*" && month === "*" && dayOfWeek === "*") {
    const interval = parsePositiveInteger(hour.slice(2))
    return interval && interval <= 23 && isValidMinute(minute) ? `Every ${pluralize(interval, "hour")} at minute ${padTimePart(minute)}` : null
  }

  if (!isValidMinute(minute) || !isValidHour(hour)) return null

  const time = `${padTimePart(hour)}:${padTimePart(minute)}`
  if (dayOfMonth === "*" && month === "*" && dayOfWeek === "*") return `Every day at ${time}`

  if (dayOfMonth === "*" && month === "*" && isSingleWeekday(dayOfWeek)) {
    return `Every ${WEEKDAYS[normalizedWeekday(dayOfWeek)]} at ${time}`
  }

  if (isValidDayOfMonth(dayOfMonth) && month === "*" && dayOfWeek === "*") {
    return `Every month on day ${Number(dayOfMonth)} at ${time}`
  }

  if (isValidDayOfMonth(dayOfMonth) && isValidMonth(month) && dayOfWeek === "*") {
    return `Every ${monthName(Number(month))} ${Number(dayOfMonth)} at ${time}`
  }

  return null
}

function explainCronMacro(expression: string): string | null {
  switch (expression) {
    case "@hourly":
      return "Every hour"
    case "@daily":
    case "@midnight":
      return "Every day at 00:00"
    case "@weekly":
      return "Every Sunday at 00:00"
    case "@monthly":
      return "Every month on day 1 at 00:00"
    case "@yearly":
    case "@annually":
      return "Every January 1 at 00:00"
    default:
      return null
  }
}

function isSingleWeekday(value: string): boolean {
  if (!isInteger(value)) return false
  const day = normalizedWeekday(value)
  return day >= 0 && day <= 6
}

function normalizedWeekday(value: string): number {
  const day = Number(value)
  return day === 7 ? 0 : day
}

function monthName(value: number): string {
  return new Date(Date.UTC(2026, value - 1, 1)).toLocaleString("en-US", { month: "long", timeZone: "UTC" })
}

function parsePositiveInteger(value: string): number | null {
  if (!isInteger(value)) return null
  const number = Number(value)
  return number > 0 ? number : null
}

function isInteger(value: string): boolean {
  return /^\d+$/.test(value)
}

function isValidMinute(value: string): boolean {
  if (!isInteger(value)) return false
  const number = Number(value)
  return number >= 0 && number <= 59
}

function isValidHour(value: string): boolean {
  if (!isInteger(value)) return false
  const number = Number(value)
  return number >= 0 && number <= 23
}

function isValidDayOfMonth(value: string): boolean {
  if (!isInteger(value)) return false
  const number = Number(value)
  return number >= 1 && number <= 31
}

function isValidMonth(value: string): boolean {
  if (!isInteger(value)) return false
  const number = Number(value)
  return number >= 1 && number <= 12
}

function padTimePart(value: string): string {
  return value.padStart(2, "0")
}

function pluralize(count: number, unit: string): string {
  return `${count} ${unit}${count === 1 ? "" : "s"}`
}
