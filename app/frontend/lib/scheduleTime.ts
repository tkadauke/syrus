export type ParsedSchedule = {
  fireAt: Date
  body: string
}

const MINUTE_MS = 60 * 1000
const HOUR_MS = 60 * MINUTE_MS
const DAY_MS = 24 * HOUR_MS

export function parseScheduleCommandArgs(argsText: string, now = new Date()): ParsedSchedule | null {
  const trimmed = argsText.trim()
  if (!trimmed) return null

  const tokens = trimmed.split(/\s+/)
  for (let count = Math.min(tokens.length - 1, 4); count >= 1; count -= 1) {
    const timeText = tokens.slice(0, count).join(" ")
    const body = tokens.slice(count).join(" ").trim()
    if (!body) continue

    const fireAt = parseScheduleTime(timeText, now)
    if (fireAt) return { fireAt, body }
  }

  return null
}

export function parseScheduleTime(input: string, now = new Date()): Date | null {
  const value = input.trim().toLowerCase()
  if (!value) return null

  const shorthand = value.match(/^(\d+)\s*([mhd])$/)
  if (shorthand) return offsetFrom(now, Number(shorthand[1]), shorthand[2])

  const relative = value.match(/^in\s+(\d+)\s*(minute|minutes|min|mins|m|hour|hours|hr|hrs|h|day|days|d)$/)
  if (relative) return offsetFrom(now, Number(relative[1]), relative[2][0])

  const tomorrow = value.match(/^tomorrow(?:\s+(.+))?$/)
  if (tomorrow) {
    const date = new Date(now)
    date.setDate(date.getDate() + 1)
    date.setHours(9, 0, 0, 0)
    return tomorrow[1] ? applyClock(date, tomorrow[1]) : date
  }

  const todayClock = applyClock(new Date(now), value)
  if (todayClock) {
    if (todayClock <= now) todayClock.setDate(todayClock.getDate() + 1)
    return todayClock
  }

  return null
}

export function formatScheduledTime(date: Date) {
  return new Intl.DateTimeFormat(undefined, {
    dateStyle: "medium",
    timeStyle: "short"
  }).format(date)
}

function offsetFrom(now: Date, amount: number, unit: string) {
  if (!Number.isFinite(amount) || amount <= 0) return null

  const multiplier = unit === "m" ? MINUTE_MS : unit === "h" ? HOUR_MS : DAY_MS
  return new Date(now.getTime() + amount * multiplier)
}

function applyClock(date: Date, clockText: string) {
  const match = clockText.trim().match(/^(\d{1,2})(?::(\d{2}))?\s*(am|pm)?$/)
  if (!match) return null

  let hour = Number(match[1])
  const minute = match[2] == null ? 0 : Number(match[2])
  const period = match[3]
  if (hour > 23 || minute > 59) return null
  if (period && hour > 12) return null
  if (period === "am" && hour === 12) hour = 0
  if (period === "pm" && hour < 12) hour += 12

  const result = new Date(date)
  result.setHours(hour, minute, 0, 0)
  return result
}
