import { scaleTime, type ScaleTime } from "d3-scale"
import { select } from "d3-selection"
import { zoom as d3zoom, zoomIdentity, type ZoomTransform } from "d3-zoom"
import { useEffect, useMemo, useRef, useState } from "react"
import { useT } from "@app/hooks/useT"
import type { WorkerTimelineLane, WorkerTimelineMacroPayload, WorkerTimelineSpan } from "../api/workerTimeline"

const ROW_HEIGHT = 44
const DEFAULT_VIEWPORT_HEIGHT = 480
const BUFFER_ROWS = 3
const CHART_WIDTH = 1000

const STATUS_COLORS: Record<string, string> = {
  queued: "#f59e0b",
  running: "#2563eb",
  succeeded: "#16a34a",
  failed: "#dc2626",
  cancelled: "#6b7280"
}

type TooltipState = {
  span: WorkerTimelineSpan
  x: number
  y: number
}

export function TimelineLanes({
  payload,
  onSelectWorkflow
}: {
  payload: WorkerTimelineMacroPayload
  onSelectWorkflow: (workflowId: number) => void
}) {
  const { t } = useT("worker_timeline")
  const scrollRef = useRef<HTMLDivElement | null>(null)
  const zoomRef = useRef<HTMLDivElement | null>(null)
  const [scrollTop, setScrollTop] = useState(0)
  const [viewportHeight, setViewportHeight] = useState(DEFAULT_VIEWPORT_HEIGHT)
  const [transform, setTransform] = useState<ZoomTransform>(zoomIdentity)
  const [tooltip, setTooltip] = useState<TooltipState | null>(null)

  const lanes = payload.lanes

  const baseScale = useMemo(
    () => scaleTime().domain([ new Date(payload.range.from), new Date(payload.range.to) ]).range([ 0, CHART_WIDTH ]),
    [ payload.range.from, payload.range.to ]
  )
  const xScale = useMemo(() => transform.rescaleX(baseScale), [ baseScale, transform ])

  useEffect(() => {
    const el = scrollRef.current
    if (!el) return

    const measure = () => {
      if (el.clientHeight > 0) setViewportHeight(el.clientHeight)
    }
    measure()

    if (typeof ResizeObserver === "undefined") return undefined
    const observer = new ResizeObserver(measure)
    observer.observe(el)
    return () => observer.disconnect()
  }, [])

  useEffect(() => {
    const el = zoomRef.current
    if (!el) return undefined

    const behavior = d3zoom<HTMLDivElement, unknown>()
      .scaleExtent([ 1, 200 ])
      .translateExtent([ [ 0, 0 ], [ CHART_WIDTH, 0 ] ])
      .extent([ [ 0, 0 ], [ CHART_WIDTH, 0 ] ])
      .on("zoom", (event) => setTransform(event.transform))

    const selection = select(el)
    selection.call(behavior)
    return () => {
      selection.on(".zoom", null)
    }
  }, [])

  const startIndex = Math.max(0, Math.floor(scrollTop / ROW_HEIGHT) - BUFFER_ROWS)
  const endIndex = Math.min(lanes.length, Math.ceil((scrollTop + viewportHeight) / ROW_HEIGHT) + BUFFER_ROWS)
  const visibleLanes = lanes.slice(startIndex, endIndex)
  const totalHeight = lanes.length * ROW_HEIGHT

  if (lanes.length === 0) {
    return <p className="p-6 text-sm text-gray-500 dark:text-gray-400">{t("no_lanes")}</p>
  }

  return (
    <div className="relative">
      <TimeAxis scale={xScale} />
      <div
        aria-label={t("lanes_aria")}
        className="relative h-[480px] overflow-y-auto overflow-x-hidden border-t border-gray-200 dark:border-gray-800"
        onScroll={(event) => setScrollTop(event.currentTarget.scrollTop)}
        ref={scrollRef}
      >
        <div ref={zoomRef} style={{ height: totalHeight, position: "relative" }}>
          {visibleLanes.map((lane, offset) => (
            <LaneRow
              index={startIndex + offset}
              key={`${lane.hostname ?? "unknown"}:${lane.pid ?? "idle"}`}
              lane={lane}
              onHover={setTooltip}
              onSelectWorkflow={onSelectWorkflow}
              scale={xScale}
            />
          ))}
        </div>
      </div>
      {tooltip ? <SpanTooltip span={tooltip.span} x={tooltip.x} y={tooltip.y} /> : null}
    </div>
  )
}

function TimeAxis({ scale }: { scale: ScaleTime<number, number> }) {
  const ticks = scale.ticks(6)
  return (
    <svg aria-hidden="true" className="h-6 w-full" preserveAspectRatio="none" viewBox={`0 0 ${CHART_WIDTH} 24`}>
      {ticks.map((tick) => (
        <text fill="currentColor" fontSize="9" key={tick.toISOString()} textAnchor="middle" x={scale(tick)} y="16">
          {tick.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })}
        </text>
      ))}
    </svg>
  )
}

function LaneRow({
  lane,
  index,
  scale,
  onHover,
  onSelectWorkflow
}: {
  lane: WorkerTimelineLane
  index: number
  scale: ScaleTime<number, number>
  onHover: (tooltip: TooltipState | null) => void
  onSelectWorkflow: (workflowId: number) => void
}) {
  const laneLabel = lane.pid ? `${lane.hostname ?? "?"}:${lane.pid}` : `${lane.hostname ?? "?"} (idle)`

  return (
    <div
      className="absolute left-0 right-0 flex items-center gap-2 border-b border-gray-100 dark:border-gray-800"
      style={{ top: index * ROW_HEIGHT, height: ROW_HEIGHT }}
    >
      <div className="w-40 shrink-0 truncate px-2 font-mono text-xs text-gray-600 dark:text-gray-400" title={laneLabel}>
        {laneLabel}
      </div>
      <svg className="h-8 flex-1" preserveAspectRatio="none" role="img" viewBox={`0 0 ${CHART_WIDTH} 32`}>
        {lane.spans.map((span) => {
          const x = scale(new Date(span.started_at))
          const endDate = span.finished_at ? new Date(span.finished_at) : new Date()
          const width = Math.max(2, scale(endDate) - x)
          return (
            <rect
              aria-label={span.label}
              data-workflow-id={span.workflow_id}
              fill={STATUS_COLORS[span.status] ?? "#94a3b8"}
              height="20"
              key={span.workflow_id}
              onClick={() => onSelectWorkflow(span.workflow_id)}
              onMouseEnter={(event) => onHover({ span, x: event.clientX, y: event.clientY })}
              onMouseLeave={() => onHover(null)}
              onMouseMove={(event) => onHover({ span, x: event.clientX, y: event.clientY })}
              rx="3"
              role="button"
              style={{ cursor: "pointer" }}
              tabIndex={0}
              width={width}
              x={x}
              y="6"
            />
          )
        })}
      </svg>
    </div>
  )
}

function SpanTooltip({ span, x, y }: { span: WorkerTimelineSpan; x: number; y: number }) {
  const { t } = useT("worker_timeline")
  const duration = formatDuration(span)
  const blockedText = blockedMessage(span, t)

  return (
    <div
      className="pointer-events-none fixed z-50 max-w-xs rounded border border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-900 p-2 text-xs text-gray-800 dark:text-gray-100 shadow-lg"
      role="tooltip"
      style={{ left: x + 12, top: y + 12 }}
    >
      <p className="font-semibold">{span.label}</p>
      <p className="text-gray-500 dark:text-gray-400">{t("tooltip_workflow", { id: span.workflow_id })}</p>
      <p>{duration}</p>
      <p className="mt-1 text-gray-600 dark:text-gray-300">{blockedText}</p>
    </div>
  )
}

function formatDuration(span: WorkerTimelineSpan): string {
  const start = new Date(span.started_at).getTime()
  const end = span.finished_at ? new Date(span.finished_at).getTime() : Date.now()
  const totalSeconds = Math.max(0, Math.round((end - start) / 1000))
  const hours = Math.floor(totalSeconds / 3600)
  const minutes = Math.floor((totalSeconds % 3600) / 60)
  const seconds = totalSeconds % 60
  const parts = []
  if (hours) parts.push(`${hours}h`)
  if (hours || minutes) parts.push(`${minutes}m`)
  parts.push(`${seconds}s`)

  const label = parts.join(" ")
  return span.finished_at ? label : `${label}+ (running)`
}

function blockedMessage(span: WorkerTimelineSpan, t: (key: string, options?: Record<string, unknown>) => string): string {
  const blocked = span.blocked
  if (!blocked.available) {
    return blocked.historical ? t("no_historical_blocker_data") : t("no_blocker_data")
  }

  return t("blocked_reason_line", { reason: blocked.blocked_reason })
}
