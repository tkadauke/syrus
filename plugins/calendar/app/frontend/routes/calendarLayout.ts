import type { CalendarEvent } from "../api/calendar"

export const HOUR_HEIGHT = 48
export const DAY_HEIGHT = HOUR_HEIGHT * 24
export const MINIMUM_VISIBLE_MINUTES = 15
export const FALLBACK_DURATION_SECONDS = 30 * 60

export function addCalendarDays(input: Date, days: number) {
  const date = new Date(input)
  date.setDate(date.getDate() + days)
  return date
}

export type DurationResolution = {
  seconds: number
  provenance: "actual" | "planned" | "representative" | "source" | "fallback"
  estimated: boolean
}

export type PositionedEvent = {
  event: CalendarEvent
  dayKey: string
  startMinute: number
  duration: DurationResolution
  top: number
  height: number
  lane: number
  laneCount: number
}

export function zonedParts(value: Date, timeZone: string) {
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    hourCycle: "h23"
  }).formatToParts(value)
  const part = (type: Intl.DateTimeFormatPartTypes) => parts.find((item) => item.type === type)?.value ?? ""
  return {
    dayKey: `${part("year")}-${part("month")}-${part("day")}`,
    minute: Number(part("hour")) * 60 + Number(part("minute"))
  }
}

export function resolveDuration(event: CalendarEvent, now = new Date()): DurationResolution {
  if (event.actual_started_at) {
    const finish = event.actual_finished_at ? new Date(event.actual_finished_at) : now
    const seconds = (finish.getTime() - new Date(event.actual_started_at).getTime()) / 1000
    if (seconds > 0) return { seconds, provenance: "actual", estimated: false }
  }
  if (event.ends_at) {
    const seconds = (new Date(event.ends_at).getTime() - new Date(event.starts_at).getTime()) / 1000
    if (seconds > 0) return { seconds, provenance: "planned", estimated: false }
  }
  if (event.estimated_duration_seconds && event.estimated_duration_seconds > 0) {
    return {
      seconds: event.estimated_duration_seconds,
      provenance: event.duration_estimate_provenance ?? "source",
      estimated: true
    }
  }
  return { seconds: FALLBACK_DURATION_SECONDS, provenance: "fallback", estimated: true }
}

export function positionEvents(events: CalendarEvent[], timeZone: string, now = new Date()): PositionedEvent[] {
  const positioned = events.map((event) => {
    const start = zonedParts(new Date(event.starts_at), timeZone)
    const duration = resolveDuration(event, now)
    const visibleMinutes = Math.max(MINIMUM_VISIBLE_MINUTES, duration.seconds / 60)
    return {
      event,
      dayKey: start.dayKey,
      startMinute: start.minute,
      duration,
      top: (start.minute / 60) * HOUR_HEIGHT,
      height: (Math.min(visibleMinutes, 24 * 60 - start.minute) / 60) * HOUR_HEIGHT,
      lane: 0,
      laneCount: 1
    }
  })

  const byDay = new Map<string, PositionedEvent[]>()
  for (const item of positioned) byDay.set(item.dayKey, [...(byDay.get(item.dayKey) ?? []), item])
  for (const daily of byDay.values()) {
    daily.sort((left, right) => left.startMinute - right.startMinute || right.height - left.height)
    let cluster: PositionedEvent[] = []
    let clusterEnd = -1
    const finishCluster = () => {
      const laneEnds: number[] = []
      for (const item of cluster) {
        const lane = laneEnds.findIndex((end) => end <= item.startMinute)
        item.lane = lane === -1 ? laneEnds.length : lane
        laneEnds[item.lane] = item.startMinute + Math.max(MINIMUM_VISIBLE_MINUTES, item.duration.seconds / 60)
      }
      for (const item of cluster) item.laneCount = laneEnds.length
    }
    for (const item of daily) {
      if (cluster.length && item.startMinute >= clusterEnd) {
        finishCluster()
        cluster = []
      }
      cluster.push(item)
      clusterEnd = Math.max(clusterEnd, item.startMinute + Math.max(MINIMUM_VISIBLE_MINUTES, item.duration.seconds / 60))
    }
    finishCluster()
  }
  return positioned
}
