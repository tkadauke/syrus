import { routePrefix, withRoutePrefix } from "../lib/routing"
import { keepPreviousData, useQuery } from "@tanstack/react-query"
import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState, type UIEvent, type ReactNode } from "react"
import { Link, useLocation, useParams, useSearchParams } from "react-router-dom"
import { ApiError } from "../api/client"
import { fetchAdminTranscript, type TranscriptPayload } from "../api/adminTranscript"
import { AnsiText } from "../components/AnsiText"
import { Markdown } from "../lib/Markdown"
import { useT } from "../hooks/useT"
import { ToolGroup } from "./chat/MessageCards"
import { groupTranscriptEvents, type AdminTranscriptRenderItem } from "./adminTranscriptGrouping"

const DEFAULT_PER_PAGE = 100
const TRANSCRIPT_BOTTOM_THRESHOLD_PX = 48
const TRANSCRIPT_REFETCH_INTERVAL_MS = 2000

export function AdminTranscript() {
  const { t } = useT("admin")
  const params = useParams()
  const location = useLocation()
  const runId = params.runId || ""
  const [searchParams] = useSearchParams()
  const prefix = routePrefix(location.pathname)
  const page = positiveInteger(searchParams.get("page"), 1)
  const per = positiveInteger(searchParams.get("per"), DEFAULT_PER_PAGE)
  const transcript = useQuery({
    queryKey: ["admin", "transcript", runId, { page, per }],
    queryFn: () => fetchAdminTranscript(runId, page, per),
    enabled: runId.length > 0,
    refetchInterval: TRANSCRIPT_REFETCH_INTERVAL_MS,
    placeholderData: keepPreviousData
  })

  return (
    <main aria-label={t("transcript.aria_index")} className="mx-auto flex h-[calc(100vh-4rem)] max-w-6xl flex-col gap-6 overflow-hidden p-6">
      {transcript.isPending ? <PanelMessage>{t("transcript.loading")}</PanelMessage> : null}
      {transcript.isError ? <TranscriptError error={transcript.error} /> : null}
      {transcript.isSuccess ? <TranscriptView payload={transcript.data} prefix={prefix} /> : null}
    </main>
  )
}

function TranscriptView({ payload, prefix }: { payload: TranscriptPayload; prefix: string }) {
  const { t } = useT("admin")

  return (
    <>
      <header className="shrink-0 flex flex-col gap-3 border-b border-gray-200 dark:border-gray-700 pb-4 sm:flex-row sm:items-start sm:justify-between">
        <div>
          <div className="text-xs uppercase text-gray-500 dark:text-gray-400">
            <Link className="underline hover:no-underline" to={withRoutePrefix(`/jobs/${payload.job_id}`, prefix)}>back to JOB-{payload.job_id}</Link>
          </div>
          <h1 className="mt-1 text-2xl font-semibold text-gray-900 dark:text-gray-100">
            Run #{payload.run_id} · transcript
          </h1>
          <p className="mt-1 text-sm text-gray-500 dark:text-gray-400">
            Session <span className="font-mono">{payload.session_id}</span>
            {payload.summary.model ? <> · {payload.summary.model}</> : null}
            {payload.step_kind ? <> · {payload.step_kind}</> : null}
            {payload.workflow_trigger_kind ? <> · {payload.workflow_trigger_kind}</> : null}
          </p>
        </div>
        <a className="text-sm text-blue-600 dark:text-blue-300 underline hover:no-underline" href={`/admin/runs/${payload.run_id}/transcript/download`}>
          {t("transcript.download_jsonl")}
        </a>
      </header>

      <SummaryGrid payload={payload} />
      <Pagination payload={payload} />

      <TranscriptEventStream payload={payload} />
    </>
  )
}

function TranscriptEventStream({ payload }: { payload: TranscriptPayload }) {
  const { t } = useT("admin")
  const streamRef = useRef<HTMLDivElement | null>(null)
  const atBottomRef = useRef(true)
  const totalEventsRef = useRef(payload.pagination.total_events)
  const streamPageRef = useRef(transcriptPageKey(payload))
  const [hasNewMessages, setHasNewMessages] = useState(false)
  const eventSignature = transcriptEventSignature(payload)
  const items = useMemo(() => groupTranscriptEvents(payload.events), [payload])

  const scrollToBottom = useCallback(() => {
    scrollTranscriptStreamToBottom(streamRef.current)
    atBottomRef.current = true
    setHasNewMessages(false)
  }, [])

  const handleScroll = useCallback((event: UIEvent<HTMLDivElement>) => {
    const atBottom = isTranscriptStreamAtBottom(event.currentTarget)
    atBottomRef.current = atBottom
    if (atBottom) setHasNewMessages(false)
  }, [])

  useEffect(() => {
    const pageKey = transcriptPageKey(payload)
    if (streamPageRef.current !== pageKey) {
      streamPageRef.current = pageKey
      totalEventsRef.current = payload.pagination.total_events
      atBottomRef.current = true
      setHasNewMessages(false)
      return
    }

    const previousTotalEvents = totalEventsRef.current
    if (payload.pagination.total_events > previousTotalEvents && !atBottomRef.current) {
      setHasNewMessages(true)
    }
    totalEventsRef.current = payload.pagination.total_events
  }, [payload])

  useLayoutEffect(() => {
    if (atBottomRef.current) scrollTranscriptStreamToBottom(streamRef.current)
  }, [eventSignature])

  return (
    <div className="relative min-h-0 flex-1">
      <section
        aria-label={t("transcript.aria_events")}
        className="h-full min-h-0 space-y-3 overflow-y-auto pr-2"
        data-testid="transcript-event-stream"
        onScroll={handleScroll}
        ref={streamRef}
      >
        {items.length === 0 ? <PanelMessage>{t("transcript.no_events")}</PanelMessage> : null}
        {items.map((item) => (
          <TranscriptRenderItemView item={item} key={item.key} />
        ))}
      </section>
      {hasNewMessages ? (
        <NewMessagesButton onClick={scrollToBottom} />
      ) : null}
    </div>
  )
}

function NewMessagesButton({ onClick }: { onClick: () => void }) {
  const { t } = useT("admin")

  return (
    <button
      className="absolute bottom-4 left-1/2 -translate-x-1/2 rounded-full bg-gray-900 dark:bg-gray-100 px-4 py-2 text-sm font-medium text-white dark:text-gray-900 shadow-lg hover:bg-gray-800 dark:hover:bg-gray-200"
      onClick={onClick}
      type="button"
    >
      {t("transcript.new_messages")}
    </button>
  )
}

function SummaryGrid({ payload }: { payload: TranscriptPayload }) {
  const { t } = useT("admin")
  const summary = payload.summary

  return (
    <section aria-label={t("transcript.aria_summary")} className="grid gap-4 rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 p-4 text-sm sm:grid-cols-2 lg:grid-cols-4">
      <SummaryItem label={t("transcript.turns")} value={summary.total_turns ?? "-"} />
      <SummaryItem label={t("transcript.tool_calls")} value={summary.total_tool_calls} />
      <SummaryItem label={t("transcript.cost")} value={summary.total_cost_usd == null ? "-" : `$${summary.total_cost_usd.toFixed(4)}`} />
      <SummaryItem label={t("transcript.exit_reason")} value={summary.exit_reason || "-"} mono />
      <div className="border-t border-gray-100 dark:border-gray-800 pt-3 sm:col-span-2 lg:col-span-4">
        <div className="mb-2 text-xs uppercase text-gray-500 dark:text-gray-400">{t("transcript.tool_call_breakdown")}</div>
        {Object.keys(summary.tool_call_counts).length > 0 ? (
          <div className="flex flex-wrap gap-2">
            {Object.entries(summary.tool_call_counts).map(([name, count]) => (
              <span className="rounded bg-gray-100 dark:bg-gray-800 px-2 py-0.5 font-mono text-xs text-gray-700 dark:text-gray-200" key={name}>{name} x{count}</span>
            ))}
          </div>
        ) : (
          <span className="text-xs italic text-gray-400">{t("transcript.no_tool_calls")}</span>
        )}
      </div>
    </section>
  )
}

function SummaryItem({ label, value, mono = false }: { label: string; value: ReactNode; mono?: boolean }) {
  return (
    <div>
      <div className="text-xs uppercase text-gray-500 dark:text-gray-400">{label}</div>
      <div className={`font-medium text-gray-900 dark:text-gray-100 ${mono ? "font-mono text-xs" : ""}`}>{value}</div>
    </div>
  )
}

function Pagination({ payload }: { payload: TranscriptPayload }) {
  const { t } = useT("admin")
  const location = useLocation()
  const basePath = location.pathname
  const { page, per, total_pages: totalPages, total_events: totalEvents } = payload.pagination

  if (totalPages <= 1) {
    return <p className="text-sm text-gray-600 dark:text-gray-300">{t("transcript.showing_events", { count: totalEvents })}</p>
  }

  return (
    <nav aria-label={t("transcript.aria_pagination")} className="flex items-center justify-between text-sm text-gray-600 dark:text-gray-300">
      <span>{t("transcript.page_of", { page, total: totalPages, events: totalEvents })}</span>
      <div className="flex gap-2">
        {page > 1 ? (
          <Link className="rounded border border-gray-300 dark:border-gray-600 px-3 py-1 hover:bg-gray-50 dark:hover:bg-gray-800" to={`${basePath}?page=${page - 1}&per=${per}`}>{t("transcript.previous")}</Link>
        ) : (
          <span className="rounded border border-gray-200 dark:border-gray-700 px-3 py-1 text-gray-300">{t("transcript.previous")}</span>
        )}
        {page < totalPages ? (
          <Link className="rounded border border-gray-300 dark:border-gray-600 px-3 py-1 hover:bg-gray-50 dark:hover:bg-gray-800" to={`${basePath}?page=${page + 1}&per=${per}`}>{t("transcript.next")}</Link>
        ) : (
          <span className="rounded border border-gray-200 dark:border-gray-700 px-3 py-1 text-gray-300">{t("transcript.next")}</span>
        )}
      </div>
    </nav>
  )
}

function TranscriptRenderItemView({ item }: { item: AdminTranscriptRenderItem }) {
  const { t } = useT("admin")

  switch (item.type) {
    case "tool_group":
      return <ToolGroup item={item} />
    case "text":
      if (item.kind === "user_prompt") {
        return (
          <div className="flex justify-end">
            <pre className="max-w-[85%] whitespace-pre-wrap break-words rounded bg-blue-600 px-4 py-2 text-sm leading-normal text-white dark:bg-blue-500"><AnsiText text={item.text} /></pre>
          </div>
        )
      }
      if (item.kind === "assistant_text") {
        return (
          <div className="rounded border border-gray-200 bg-white px-4 py-3 dark:border-gray-700 dark:bg-gray-900">
            <Markdown className="chat-prose text-gray-800 dark:text-gray-100" text={item.text} />
          </div>
        )
      }
      return (
        <div className="rounded border border-gray-200 bg-white px-3 py-2 text-xs text-gray-500 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-400">
          <div className="mb-1 font-medium uppercase">job log</div>
          <pre className="whitespace-pre-wrap break-words font-mono"><AnsiText text={item.text} /></pre>
        </div>
      )
    case "system_init":
      return <DetailsCard badge="init" title={`${stringValue(item.data.model)} · ${stringValue(item.data.cwd)}`} data={item.data} />
    case "result":
      return <ResultCard data={item.data} />
    case "fallback":
      return <DetailsCard badge={item.badge} title={item.title ?? t("transcript.other_event")} data={item.data} tone={item.tone} />
    default:
      return null
  }
}

function DetailsCard({ badge, title, data, tone = "gray" }: { badge: string; title: string; data: unknown; tone?: "gray" | "red" | "emerald" }) {
  const badgeClass = {
    gray: "bg-gray-100  text-gray-700 dark:text-gray-200",
    red: "bg-red-100 dark:bg-red-950/60 text-red-700 dark:text-red-300",
    emerald: "bg-emerald-100 dark:bg-emerald-950/60 text-emerald-700 dark:text-emerald-300"
  }[tone]

  return (
    <details className="rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 text-xs">
      <summary className="flex cursor-pointer items-center gap-2 px-3 py-2">
        <span className={`rounded px-1.5 py-0.5 font-mono uppercase ${badgeClass}`}>{badge}</span>
        <span className="truncate font-mono text-gray-800 dark:text-gray-100">{title}</span>
      </summary>
      <pre className="overflow-x-auto whitespace-pre-wrap break-words px-3 pb-3 font-mono text-gray-600 dark:text-gray-300"><AnsiText text={pretty(data)} /></pre>
    </details>
  )
}

function ResultCard({ data }: { data: Record<string, unknown> }) {
  const isError = data.is_error === true

  return (
    <div className={`rounded border px-3 py-2 text-xs ${isError ? "border-red-200 dark:border-red-800 bg-red-50 dark:bg-red-950/40" : "border-emerald-200 dark:border-emerald-800 bg-emerald-50 dark:bg-emerald-950/40"}`}>
      <div className="flex flex-wrap gap-3 font-mono">
        <span className={`font-semibold uppercase ${isError ? "text-red-700 dark:text-red-300" : "text-emerald-700 dark:text-emerald-300"}`}>result</span>
        <span>turns={stringValue(data.turns)}</span>
        <span>duration={stringValue(data.duration_ms)}ms</span>
        <span>subtype={stringValue(data.subtype)}</span>
      </div>
      {data.final_text != null && data.final_text !== "" ? <pre className="mt-2 whitespace-pre-wrap break-words text-sm text-gray-800 dark:text-gray-100"><AnsiText text={stringValue(data.final_text)} /></pre> : null}
    </div>
  )
}

function TranscriptError({ error }: { error: Error }) {
  const { t } = useT("admin")
  const message = error instanceof ApiError ? error.message : t("transcript.error_load")

  return <PanelMessage tone="error">{message}</PanelMessage>
}

function PanelMessage({ children, tone = "muted" }: { children: ReactNode; tone?: "muted" | "error" }) {
  return <div className={`rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 p-4 text-sm ${tone === "error" ? "text-red-700 dark:text-red-300" : "text-gray-600 dark:text-gray-300"}`}>{children}</div>
}

function positiveInteger(value: string | null, fallback: number) {
  const parsed = Number(value)
  return Number.isFinite(parsed) && parsed > 0 ? Math.floor(parsed) : fallback
}

function stringValue(value: unknown) {
  if (value == null) return "-"
  return String(value)
}

function pretty(value: unknown) {
  if (typeof value === "string") return value
  return JSON.stringify(value ?? {}, null, 2)
}

function transcriptPageKey(payload: TranscriptPayload) {
  const { page, per } = payload.pagination
  return `${payload.run_id}:${page}:${per}`
}

function transcriptEventSignature(payload: TranscriptPayload) {
  return `${payload.pagination.total_events}:${payload.events.map((event, index) => `${event.kind}:${event.timestamp || index}`).join("|")}`
}

function isTranscriptStreamAtBottom(element: HTMLElement) {
  return element.scrollHeight - element.scrollTop - element.clientHeight <= TRANSCRIPT_BOTTOM_THRESHOLD_PX
}

function scrollTranscriptStreamToBottom(element: HTMLElement | null) {
  if (!element) return

  element.scrollTop = element.scrollHeight
}
