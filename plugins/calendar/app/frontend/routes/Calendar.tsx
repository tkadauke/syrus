import { useQuery } from "@tanstack/react-query"
import { useMemo, useState } from "react"
import { Link, useLocation } from "react-router-dom"
import { FilterBar, topFilterChildren, type FilterChip, type FilterSchemaField, type FilterTree } from "@app/components/FilterBar"
import { Avatar } from "@app/components/Avatar"
import { Notice, Page, PageHeading, Section, Text } from "@app/components/ui"
import { usePageTitle } from "@app/hooks/usePageTitle"
import { useT } from "@app/hooks/useT"
import { fetchCalendar, type CalendarEvent } from "../api/calendar"
import { addCalendarDays, DAY_HEIGHT, HOUR_HEIGHT, positionEvents, resolveDuration, zonedParts, type DurationResolution } from "./calendarLayout"

export default function CalendarRoute() {
  const { t, i18n } = useT("calendar")
  const location = useLocation()
  usePageTitle(t("title"))
  const [anchor, setAnchor] = useState(() => startOfWeek(new Date()))
  const [view, setView] = useState<"week" | "agenda">("week")
  const timeZone = Intl.DateTimeFormat().resolvedOptions().timeZone
  const end = useMemo(() => addCalendarDays(anchor, 7), [anchor])
  const query = useQuery({ queryKey: ["calendar", anchor.toISOString()], queryFn: () => fetchCalendar(anchor, end) })
  const filterTree = decodeFilter(location.search)
  const sources = Array.from(new Set((query.data?.events ?? []).map((event) => event.source_id)))
  const categories = Array.from(new Set((query.data?.events ?? []).map((event) => event.kind)))
  const events = (query.data?.events ?? []).filter((event) => matchesFilters(event, filterTree))
  const filterSchema: FilterSchemaField[] = [
    { field: "source", label: t("source_filter"), bucket: "calendar", operators: ["is", "is_not"], values: sources },
    { field: "category", label: t("category_filter"), bucket: "calendar", operators: ["is", "is_not"], values: categories }
  ]
  const formatter = new Intl.DateTimeFormat(i18n.language, { weekday: "short", month: "short", day: "numeric", hour: "2-digit", minute: "2-digit", timeZone })

  return (
    <Page.Root aria-label={t("title")} gutter="responsive" size="wide">
      <Page.Header className="border-b border-border pb-4">
        <Page.HeadingGroup>
          <PageHeading>{t("title")}</PageHeading>
          <Page.Description>{t("description")}</Page.Description>
        </Page.HeadingGroup>
      </Page.Header>
      <div className="flex flex-wrap items-center gap-2 py-3" aria-label={t("controls")}>
        <button className="rounded border border-border px-3 py-1.5" onClick={() => setAnchor(addCalendarDays(anchor, -7))}>
          {t("previous")}
        </button>
        <button className="rounded border border-border px-3 py-1.5" onClick={() => setAnchor(startOfWeek(new Date()))}>
          {t("today")}
        </button>
        <button className="rounded border border-border px-3 py-1.5" onClick={() => setAnchor(addCalendarDays(anchor, 7))}>
          {t("next")}
        </button>
        <FilterBar className="min-w-64 flex-1" filter={filterTree} filterSchema={filterSchema} pathname={location.pathname} search={location.search} />
        <div className="ml-auto inline-flex rounded border border-border" role="group" aria-label={t("view_filter")}>
          {(["week", "agenda"] as const).map((value) => (
            <button aria-pressed={view === value} className="px-3 py-1.5" key={value} onClick={() => setView(value)}>
              {t(value)}
            </button>
          ))}
        </div>
        <Text variant="caption" tone="muted" className="w-full text-right">
          {t("timezone", { zone: timeZone })}
        </Text>
      </div>
      {query.isPending ? <Notice>{t("loading")}</Notice> : null}
      {query.isError ? <Notice tone="danger">{t("error")}</Notice> : null}
      {query.data?.failures.length ? <Notice tone="warning">{t("partial")}</Notice> : null}
      {query.data && events.length === 0 ? <Notice>{t("empty")}</Notice> : null}
      {view === "week" ? <Week events={events} anchor={anchor} formatter={formatter} timeZone={timeZone} /> : <Agenda events={events} formatter={formatter} />}
    </Page.Root>
  )
}

function Week({ events, anchor, formatter, timeZone }: { events: CalendarEvent[]; anchor: Date; formatter: Intl.DateTimeFormat; timeZone: string }) {
  const { t } = useT("calendar")
  const bands = events.filter((event) => event.cadence?.band)
  const occurrences = events.filter((event) => !event.cadence?.band)
  const positioned = positionEvents(occurrences, timeZone)
  return (
    <div className="space-y-3">
      {bands.length ? (
        <Section.Root className="min-w-0 p-3" aria-label={t("cadence_bands")}>
          <div className="grid min-w-0 grid-cols-1 gap-2 sm:grid-cols-2 lg:grid-cols-3">
            {bands.map((event) => (
              <EventCard event={event} formatter={formatter} key={`${event.source_id}-${event.id}`} />
            ))}
          </div>
        </Section.Root>
      ) : null}
      <div className="max-h-[75vh] overflow-auto rounded border border-border" data-testid="week-time-grid">
        <div className="grid min-w-[76rem] grid-cols-[4rem_repeat(7,minmax(10rem,1fr))]">
          <div className="sticky left-0 top-0 z-30 border-b border-r border-border bg-surface" />
          {Array.from({ length: 7 }, (_, day) => {
            const date = addCalendarDays(anchor, day)
            return (
              <div className="sticky top-0 z-20 border-b border-r border-border bg-surface px-2 py-2 font-semibold" key={date.toISOString()}>
                {formatter.format(date).split(",").slice(0, 2).join(",")}
              </div>
            )
          })}
          <div className="sticky left-0 z-20 border-r border-border bg-surface" style={{ height: DAY_HEIGHT }}>
            {Array.from({ length: 24 }, (_, hour) => (
              <div className="relative border-t border-border px-1 text-right text-xs text-muted" key={hour} style={{ height: HOUR_HEIGHT }}>
                <span className="relative -top-2.5 bg-surface px-1">{String(hour).padStart(2, "0")}:00</span>
              </div>
            ))}
          </div>
          {Array.from({ length: 7 }, (_, day) => {
            const date = addCalendarDays(anchor, day)
            const dayKey = zonedParts(date, timeZone).dayKey
            const daily = positioned.filter((item) => item.dayKey === dayKey)
            return (
              <div className="relative border-r border-border" data-calendar-day={dayKey} key={dayKey} style={{ height: DAY_HEIGHT }}>
                {Array.from({ length: 24 }, (_, hour) => (
                  <div className="absolute inset-x-0 border-t border-border" key={hour} style={{ top: hour * HOUR_HEIGHT }} />
                ))}
                {daily.map((item) => (
                  <div
                    className="absolute z-10 px-0.5 focus-within:z-30"
                    data-calendar-event={item.event.id}
                    key={`${item.event.source_id}-${item.event.id}`}
                    style={{
                      top: item.top,
                      height: item.height,
                      left: `${(item.lane / item.laneCount) * 100}%`,
                      width: `${100 / item.laneCount}%`
                    }}
                  >
                    <EventCard event={item.event} formatter={formatter} compact durationResolution={item.duration} />
                  </div>
                ))}
              </div>
            )
          })}
        </div>
      </div>
    </div>
  )
}

function Agenda({ events, formatter }: { events: CalendarEvent[]; formatter: Intl.DateTimeFormat }) {
  return (
    <div className="space-y-2">
      {events.map((event) => (
        <EventCard event={event} formatter={formatter} key={`${event.source_id}-${event.id}`} />
      ))}
    </div>
  )
}

function EventCard({
  event,
  formatter,
  compact = false,
  durationResolution
}: {
  event: CalendarEvent
  formatter: Intl.DateTimeFormat
  compact?: boolean
  durationResolution?: DurationResolution
}) {
  const { t } = useT("calendar")
  const [expanded, setExpanded] = useState(false)
  const duration = typeof event.metadata.duration_seconds === "number" ? event.metadata.duration_seconds : null
  const displayDuration = durationResolution ?? resolveDuration(event)
  const taskPath = typeof event.metadata.scheduled_task_path === "string" ? event.metadata.scheduled_task_path : null
  const coworkerName = typeof event.metadata.coworker_name === "string" ? event.metadata.coworker_name : null
  const coworkerHandle = typeof event.metadata.coworker_handle === "string" ? event.metadata.coworker_handle : null
  const coworkerPath = typeof event.metadata.coworker_path === "string" ? event.metadata.coworker_path : null
  const mainChatPath = typeof event.metadata.main_chat_path === "string" ? event.metadata.main_chat_path : null
  const avatarUrl = typeof event.metadata.coworker_avatar_url === "string" ? event.metadata.coworker_avatar_url : null
  const accentHex = typeof event.metadata.coworker_accent_hex === "string" ? event.metadata.coworker_accent_hex : null
  const afterRun = typeof event.metadata.after_run === "string" ? event.metadata.after_run : null
  const systemKey = typeof event.metadata.system_key === "string" ? event.metadata.system_key : null
  const delayedReason = typeof event.metadata.delayed_reason === "string" ? event.metadata.delayed_reason : null
  const delayedReasonLabel = delayedReason ? t(`delay_reasons.${delayedReason}`, { defaultValue: delayedReason.replaceAll("_", " ") }) : null
  return (
    <article
      className={`min-w-0 rounded border bg-surface-subtle ${displayDuration.estimated ? "border-dashed border-muted" : "border-border"} ${compact && !expanded ? "h-full overflow-hidden p-1" : compact ? "relative z-30 min-h-full p-1 shadow-lg" : "p-2"}`}
    >
      <button className="w-full min-w-0 text-left" type="button" aria-expanded={expanded} onClick={() => setExpanded((value) => !value)}>
        <span className="flex min-w-0 items-center gap-2">
          {coworkerName ? <Avatar name={coworkerName} avatarUrl={avatarUrl} accentHex={accentHex} size="xs" /> : null}
          <Text className="truncate font-medium">{event.title}</Text>
        </span>
      </button>
      <Text variant="caption" tone="muted">
        {event.cadence?.band ? event.cadence.label : formatter.format(new Date(event.starts_at))}
      </Text>
      {!compact ? <span className="mt-1 inline-block rounded-full bg-surface px-2 py-0.5 text-xs">{event.state}</span> : null}
      {expanded ? (
        <div className="mt-2 space-y-1 border-t border-border pt-2">
          <Text variant="caption" tone="muted">
            {t("planned_time", { time: formatter.format(new Date(event.starts_at)) })}
          </Text>
          {event.actual_started_at ? (
            <Text variant="caption" tone="muted">
              {t("actual_time", {
                start: formatter.format(new Date(event.actual_started_at)),
                finish: event.actual_finished_at ? formatter.format(new Date(event.actual_finished_at)) : t("running")
              })}
            </Text>
          ) : null}
          {duration != null ? (
            <Text variant="caption" tone="muted">
              {t("duration", { seconds: duration.toFixed(1) })}
            </Text>
          ) : null}
          <Text variant="caption" tone="muted">
            {t("display_duration", {
              minutes: Math.round(displayDuration.seconds / 60),
              provenance: t(`duration_provenance.${displayDuration.provenance}`)
            })}
          </Text>
          {coworkerName ? (
            <Text variant="caption" tone="muted">
              {t("coworker_identity", { name: coworkerName, handle: coworkerHandle ? `@${coworkerHandle}` : "" })}
            </Text>
          ) : null}
          {afterRun ? (
            <Text variant="caption" tone="muted">
              {t("after_run", { policy: afterRun })}
            </Text>
          ) : null}
          {systemKey ? (
            <Text variant="caption" tone="muted">
              {t("system_schedule", { key: systemKey })}
            </Text>
          ) : null}
          {delayedReasonLabel ? (
            <Text variant="caption" tone="muted">
              {t("delayed_reason", { reason: delayedReasonLabel })}
            </Text>
          ) : null}
          <Link className="inline-block text-sm text-brand hover:underline" to={event.destination_path}>
            {t("open_owner")}
          </Link>
          {taskPath && taskPath !== event.destination_path ? (
            <Link className="ml-3 inline-block text-sm text-brand hover:underline" to={taskPath}>
              {t("open_schedule")}
            </Link>
          ) : null}
          {mainChatPath ? (
            <Link className="ml-3 inline-block text-sm text-brand hover:underline" to={mainChatPath}>
              {t("open_main_chat")}
            </Link>
          ) : null}
          {coworkerPath && coworkerPath !== event.destination_path ? (
            <Link className="ml-3 inline-block text-sm text-brand hover:underline" to={coworkerPath}>
              {t("open_coworker")}
            </Link>
          ) : null}
        </div>
      ) : null}
    </article>
  )
}

function startOfWeek(input: Date) {
  const date = new Date(input)
  date.setHours(0, 0, 0, 0)
  date.setDate(date.getDate() - ((date.getDay() + 6) % 7))
  return date
}

function decodeFilter(search: string): FilterTree {
  const encoded = new URLSearchParams(search).get("q")
  if (!encoded) return { and: [] }
  try {
    const base64 = encoded
      .replace(/-/g, "+")
      .replace(/_/g, "/")
      .padEnd(Math.ceil(encoded.length / 4) * 4, "=")
    const bytes = Uint8Array.from(atob(base64), (character) => character.charCodeAt(0))
    return JSON.parse(new TextDecoder().decode(bytes)) as FilterTree
  } catch {
    return { and: [] }
  }
}

function matchesFilters(event: CalendarEvent, tree: FilterTree) {
  return topFilterChildren(tree).every((node) => {
    const chip = ("not" in node ? node.not : node) as FilterChip
    if (!chip || !("field" in chip) || !["source", "category"].includes(chip.field) || !["is", "is_not"].includes(chip.op)) return false
    const actual = chip.field === "source" ? event.source_id : chip.field === "category" ? event.kind : null
    const equal = String(actual) === String(chip.value)
    return chip.op === "is_not" ? !equal : equal
  })
}
