import { getJson } from "@app/api/client"

export type CalendarEvent = {
  source_id: string
  id: string
  kind: string
  title: string
  starts_at: string
  ends_at?: string
  actual_started_at?: string
  actual_finished_at?: string
  cadence?: { label: string; band: boolean }
  destination_path: string
  state: string
  metadata: Record<string, unknown>
}

export type CalendarPayload = { events: CalendarEvent[]; failures: { source: string; code: string }[] }

export function fetchCalendar(startsAt: Date, endsAt: Date) {
  const query = new URLSearchParams({ starts_at: startsAt.toISOString(), ends_at: endsAt.toISOString() })
  return getJson<CalendarPayload>(`/api/v1/app/calendar/events?${query}`)
}
