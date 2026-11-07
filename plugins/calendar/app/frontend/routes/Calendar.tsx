import { useQuery } from "@tanstack/react-query"
import { useMemo, useState } from "react"
import { Link, useLocation } from "react-router-dom"
import { FilterBar, topFilterChildren, type FilterChip, type FilterSchemaField, type FilterTree } from "@app/components/FilterBar"
import { Notice, Page, PageHeading, Section, Text } from "@app/components/ui"
import { usePageTitle } from "@app/hooks/usePageTitle"
import { useT } from "@app/hooks/useT"
import { fetchCalendar, type CalendarEvent } from "../api/calendar"

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
        <button className="rounded border border-border px-3 py-1.5" onClick={() => setAnchor(new Date(anchor.getTime() - 7 * 86_400_000))}>
          {t("previous")}
        </button>
        <button className="rounded border border-border px-3 py-1.5" onClick={() => setAnchor(startOfWeek(new Date()))}>
          {t("today")}
        </button>
        <button className="rounded border border-border px-3 py-1.5" onClick={() => setAnchor(new Date(anchor.getTime() + 7 * 86_400_000))}>
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
      {view === "week" ? <Week events={events} anchor={anchor} formatter={formatter} /> : <Agenda events={events} formatter={formatter} />}
    </Page.Root>
  )
}

function Week({ events, anchor, formatter }: { events: CalendarEvent[]; anchor: Date; formatter: Intl.DateTimeFormat }) {
  const { t } = useT("calendar")
  const bands = events.filter((event) => event.cadence?.band)
  const occurrences = events.filter((event) => !event.cadence?.band)
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
      <div className="grid min-w-0 grid-cols-1 gap-2 md:grid-cols-7">
        {Array.from({ length: 7 }, (_, day) => {
          const date = addCalendarDays(anchor, day)
          const daily = occurrences.filter((event) => sameLocalDate(new Date(event.starts_at), date))
          return (
            <Section.Root className="min-w-0 p-2" key={date.toISOString()}>
              <Text className="font-semibold">{formatter.format(date).split(",").slice(0, 2).join(",")}</Text>
              <div className="mt-2 space-y-2">
                {daily.map((event) => (
                  <EventCard event={event} formatter={formatter} key={`${event.source_id}-${event.id}`} />
                ))}
              </div>
            </Section.Root>
          )
        })}
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

function EventCard({ event, formatter }: { event: CalendarEvent; formatter: Intl.DateTimeFormat }) {
  const { t } = useT("calendar")
  const [expanded, setExpanded] = useState(false)
  const duration = typeof event.metadata.duration_seconds === "number" ? event.metadata.duration_seconds : null
  const taskPath = typeof event.metadata.scheduled_task_path === "string" ? event.metadata.scheduled_task_path : null
  return (
    <article className="min-w-0 rounded border border-border bg-surface-subtle p-2">
      <button className="w-full min-w-0 text-left" type="button" aria-expanded={expanded} onClick={() => setExpanded((value) => !value)}>
        <Text className="truncate font-medium">{event.title}</Text>
      </button>
      <Text variant="caption" tone="muted">
        {event.cadence?.band ? event.cadence.label : formatter.format(new Date(event.starts_at))}
      </Text>
      <span className="mt-1 inline-block rounded-full bg-surface px-2 py-0.5 text-xs">{event.state}</span>
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
          <Link className="inline-block text-sm text-brand hover:underline" to={event.destination_path}>
            {t("open_owner")}
          </Link>
          {taskPath && taskPath !== event.destination_path ? (
            <Link className="ml-3 inline-block text-sm text-brand hover:underline" to={taskPath}>
              {t("open_schedule")}
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

function addCalendarDays(input: Date, days: number) {
  const date = new Date(input)
  date.setDate(date.getDate() + days)
  return date
}

function sameLocalDate(left: Date, right: Date) {
  return left.getFullYear() === right.getFullYear() && left.getMonth() === right.getMonth() && left.getDate() === right.getDate()
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
