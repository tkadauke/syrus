import { useQuery } from "@tanstack/react-query"
import { useCallback, useEffect, useLayoutEffect, useRef, useState, type UIEvent, type ReactNode } from "react"
import { Link, useLocation, useParams, useSearchParams } from "react-router-dom"
import { ApiError } from "../api/client"
import { fetchAdminTranscript, type TranscriptEvent, type TranscriptPayload } from "../api/adminTranscript"

const DEFAULT_PER_PAGE = 100
const TRANSCRIPT_BOTTOM_THRESHOLD_PX = 48
const TRANSCRIPT_REFETCH_INTERVAL_MS = 2000

export function AdminTranscript() {
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
    refetchInterval: TRANSCRIPT_REFETCH_INTERVAL_MS
  })

  return (
    <main aria-label="Admin transcript" className="mx-auto flex h-[calc(100vh-4rem)] max-w-6xl flex-col gap-6 overflow-hidden p-6">
      {transcript.isPending ? <PanelMessage>Loading transcript...</PanelMessage> : null}
      {transcript.isError ? <TranscriptError error={transcript.error} /> : null}
      {transcript.isSuccess ? <TranscriptView payload={transcript.data} prefix={prefix} /> : null}
    </main>
  )
}

function TranscriptView({ payload, prefix }: { payload: TranscriptPayload; prefix: string }) {
  return (
    <>
      <header className="shrink-0 flex flex-col gap-3 border-b border-gray-200 pb-4 sm:flex-row sm:items-start sm:justify-between">
        <div>
          <div className="text-xs uppercase text-gray-500">
            <Link className="underline hover:no-underline" to={withRoutePrefix(`/jobs/${payload.job_id}`, prefix)}>back to job #{payload.job_id}</Link>
          </div>
          <h1 className="mt-1 text-2xl font-semibold text-gray-900">
            Run #{payload.run_id} · transcript
          </h1>
          <p className="mt-1 text-sm text-gray-500">
            Session <span className="font-mono">{payload.session_id}</span>
            {payload.summary.model ? <> · {payload.summary.model}</> : null}
            {payload.step_kind ? <> · {payload.step_kind}</> : null}
            {payload.workflow_trigger_kind ? <> · {payload.workflow_trigger_kind}</> : null}
          </p>
        </div>
        <a className="text-sm text-blue-600 underline hover:no-underline" href={`/admin/runs/${payload.run_id}/transcript/download`}>
          Download JSONL
        </a>
      </header>

      <SummaryGrid payload={payload} />
      <Pagination payload={payload} />

      <TranscriptEventStream payload={payload} />
    </>
  )
}

function TranscriptEventStream({ payload }: { payload: TranscriptPayload }) {
  const streamRef = useRef<HTMLDivElement | null>(null)
  const atBottomRef = useRef(true)
  const totalEventsRef = useRef(payload.pagination.total_events)
  const streamPageRef = useRef(transcriptPageKey(payload))
  const [hasNewMessages, setHasNewMessages] = useState(false)
  const eventSignature = transcriptEventSignature(payload)

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
        aria-label="Transcript events"
        className="h-full min-h-0 space-y-3 overflow-y-auto pr-2"
        data-testid="transcript-event-stream"
        onScroll={handleScroll}
        ref={streamRef}
      >
        {payload.events.map((event, index) => (
          <TranscriptEventCard event={event} key={`${event.kind}-${event.timestamp || index}-${index}`} />
        ))}
      </section>
      {hasNewMessages ? (
        <button
          className="absolute bottom-4 left-1/2 -translate-x-1/2 rounded-full bg-gray-900 px-4 py-2 text-sm font-medium text-white shadow-lg hover:bg-gray-800"
          onClick={scrollToBottom}
          type="button"
        >
          New Messages
        </button>
      ) : null}
    </div>
  )
}

function SummaryGrid({ payload }: { payload: TranscriptPayload }) {
  const summary = payload.summary

  return (
    <section aria-label="Transcript summary" className="grid gap-4 rounded border border-gray-200 bg-white p-4 text-sm sm:grid-cols-2 lg:grid-cols-4">
      <SummaryItem label="Turns" value={summary.total_turns ?? "-"} />
      <SummaryItem label="Tool calls" value={summary.total_tool_calls} />
      <SummaryItem label="Cost" value={summary.total_cost_usd == null ? "-" : `$${summary.total_cost_usd.toFixed(4)}`} />
      <SummaryItem label="Exit reason" value={summary.exit_reason || "-"} mono />
      <div className="border-t border-gray-100 pt-3 sm:col-span-2 lg:col-span-4">
        <div className="mb-2 text-xs uppercase text-gray-500">Tool call breakdown</div>
        {Object.keys(summary.tool_call_counts).length > 0 ? (
          <div className="flex flex-wrap gap-2">
            {Object.entries(summary.tool_call_counts).map(([name, count]) => (
              <span className="rounded bg-gray-100 px-2 py-0.5 font-mono text-xs text-gray-700" key={name}>{name} x{count}</span>
            ))}
          </div>
        ) : (
          <span className="text-xs italic text-gray-400">no tool calls</span>
        )}
      </div>
    </section>
  )
}

function SummaryItem({ label, value, mono = false }: { label: string; value: ReactNode; mono?: boolean }) {
  return (
    <div>
      <div className="text-xs uppercase text-gray-500">{label}</div>
      <div className={`font-medium text-gray-900 ${mono ? "font-mono text-xs" : ""}`}>{value}</div>
    </div>
  )
}

function Pagination({ payload }: { payload: TranscriptPayload }) {
  const location = useLocation()
  const basePath = location.pathname
  const { page, per, total_pages: totalPages, total_events: totalEvents } = payload.pagination

  if (totalPages <= 1) {
    return <p className="text-sm text-gray-600">Showing {totalEvents} events.</p>
  }

  return (
    <nav aria-label="Transcript pagination" className="flex items-center justify-between text-sm text-gray-600">
      <span>Page {page} of {totalPages} · {totalEvents} events</span>
      <div className="flex gap-2">
        {page > 1 ? (
          <Link className="rounded border border-gray-300 px-3 py-1 hover:bg-gray-50" to={`${basePath}?page=${page - 1}&per=${per}`}>Previous</Link>
        ) : (
          <span className="rounded border border-gray-200 px-3 py-1 text-gray-300">Previous</span>
        )}
        {page < totalPages ? (
          <Link className="rounded border border-gray-300 px-3 py-1 hover:bg-gray-50" to={`${basePath}?page=${page + 1}&per=${per}`}>Next</Link>
        ) : (
          <span className="rounded border border-gray-200 px-3 py-1 text-gray-300">Next</span>
        )}
      </div>
    </nav>
  )
}

function TranscriptEventCard({ event }: { event: TranscriptEvent }) {
  const data = event.data

  switch (event.kind) {
    case "system_init":
      return <DetailsEvent badge="init" title={`${stringValue(data.model)} · ${stringValue(data.cwd)}`} data={data} />
    case "user_prompt":
      return <TextEvent badge="user prompt" tone="blue" text={stringValue(data.text)} />
    case "assistant_text":
      return <TextEvent badge="assistant" text={stringValue(data.text)} />
    case "tool_use":
      return <DetailsEvent badge="tool" title={stringValue(data.name)} data={data.input as Record<string, unknown>} />
    case "tool_result":
      return <DetailsEvent badge={data.error === true ? "tool err" : "tool ok"} title={preview(data.content)} data={data.content} tone={data.error === true ? "red" : "emerald"} />
    case "result":
      return <ResultEvent data={data} />
    default:
      return <DetailsEvent badge={event.kind} title="Other event" data={data} />
  }
}

function TextEvent({ badge, text, tone = "gray" }: { badge: string; text: string; tone?: "blue" | "gray" }) {
  const classes = tone === "blue" ? "border-blue-100 bg-blue-50 text-blue-700" : "border-gray-200 bg-white text-gray-500"

  return (
    <div className={`rounded border px-3 py-2 ${classes}`}>
      <div className="mb-1 text-xs font-medium uppercase">{badge}</div>
      <pre className="whitespace-pre-wrap break-words text-sm text-gray-800">{text}</pre>
    </div>
  )
}

function DetailsEvent({ badge, title, data, tone = "gray" }: { badge: string; title: string; data: unknown; tone?: "gray" | "red" | "emerald" }) {
  const badgeClass = {
    gray: "bg-gray-100 text-gray-700",
    red: "bg-red-100 text-red-700",
    emerald: "bg-emerald-100 text-emerald-700"
  }[tone]

  return (
    <details className="rounded border border-gray-200 bg-white text-xs">
      <summary className="flex cursor-pointer items-center gap-2 px-3 py-2">
        <span className={`rounded px-1.5 py-0.5 font-mono uppercase ${badgeClass}`}>{badge}</span>
        <span className="truncate font-mono text-gray-800">{title}</span>
      </summary>
      <pre className="overflow-x-auto whitespace-pre-wrap break-words px-3 pb-3 font-mono text-gray-600">{pretty(data)}</pre>
    </details>
  )
}

function ResultEvent({ data }: { data: Record<string, unknown> }) {
  const isError = data.is_error === true

  return (
    <div className={`rounded border px-3 py-2 text-xs ${isError ? "border-red-200 bg-red-50" : "border-emerald-200 bg-emerald-50"}`}>
      <div className="flex flex-wrap gap-3 font-mono">
        <span className={`font-semibold uppercase ${isError ? "text-red-700" : "text-emerald-700"}`}>result</span>
        <span>turns={stringValue(data.turns)}</span>
        <span>duration={stringValue(data.duration_ms)}ms</span>
        <span>subtype={stringValue(data.subtype)}</span>
      </div>
      {data.final_text != null && data.final_text !== "" ? <pre className="mt-2 whitespace-pre-wrap break-words text-sm text-gray-800">{stringValue(data.final_text)}</pre> : null}
    </div>
  )
}

function TranscriptError({ error }: { error: Error }) {
  const message = error instanceof ApiError ? error.message : "Unable to load transcript."

  return <PanelMessage tone="error">{message}</PanelMessage>
}

function PanelMessage({ children, tone = "muted" }: { children: ReactNode; tone?: "muted" | "error" }) {
  return <div className={`rounded border border-gray-200 bg-white p-4 text-sm ${tone === "error" ? "text-red-700" : "text-gray-600"}`}>{children}</div>
}

function routePrefix(pathname: string) {
  return pathname.startsWith("/app-shell") ? "/app-shell" : ""
}

function withRoutePrefix(path: string, prefix: string) {
  if (!prefix || path.startsWith(prefix)) return path
  if (!path.startsWith("/")) return path

  return `${prefix}${path}`
}

function positiveInteger(value: string | null, fallback: number) {
  const parsed = Number(value)
  return Number.isFinite(parsed) && parsed > 0 ? Math.floor(parsed) : fallback
}

function stringValue(value: unknown) {
  if (value == null) return "-"
  return String(value)
}

function preview(value: unknown) {
  return stringValue(typeof value === "string" ? value : JSON.stringify(value)).replace(/\s+/g, " ").slice(0, 150)
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
