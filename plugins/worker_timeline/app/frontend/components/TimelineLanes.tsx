import type { ScaleTime } from "d3-scale"
import { useState } from "react"
import { useT } from "@app/hooks/useT"
import type { WorkerTimelineLane, WorkerTimelineMacroPayload, WorkerTimelineSpan } from "../api/workerTimeline"
import { CHART_WIDTH, ROW_HEIGHT, STATUS_COLORS } from "./timeline/constants"
import { TimeAxis } from "./timeline/TimeAxis"
import { TimelineBar } from "./timeline/TimelineBar"
import { TooltipCard } from "./timeline/TooltipCard"
import { blockedMessage, formatDuration } from "./timeline/spanFormatting"
import { useVirtualizedRows } from "./timeline/useVirtualizedRows"
import { useZoomableTimeScale } from "./timeline/useZoomableTimeScale"

type TooltipState = {
  span: WorkerTimelineSpan
  x: number
  y: number
}

type RestartTooltipState = {
  text: string
  x: number
  y: number
}

type PackedLaneRow = {
  lane: WorkerTimelineLane
  laneLabel: string
  laneSecondaryLabel: string
  subrowIndex: number
  subrowCount: number
  spans: WorkerTimelineSpan[]
  restartMarkers: RestartMarker[]
}

type RestartMarker = {
  timestamp: string
  label: string
}

export function TimelineLanes({
  payload,
  onSelectWorkflow
}: {
  payload: WorkerTimelineMacroPayload
  onSelectWorkflow: (workflowId: number) => void
}) {
  const { t } = useT("worker_timeline")
  const [tooltip, setTooltip] = useState<TooltipState | null>(null)
  const [restartTooltip, setRestartTooltip] = useState<RestartTooltipState | null>(null)

  const lanes = buildPackedLaneRows(payload.lanes, t)

  const { axisRef, xScale } = useZoomableTimeScale(payload.range.from, payload.range.to)
  const { scrollRef, startIndex, endIndex, totalHeight, onScroll } = useVirtualizedRows(lanes.length, ROW_HEIGHT)
  const visibleLanes = lanes.slice(startIndex, endIndex)

  if (lanes.length === 0) {
    return <p className="p-6 text-sm text-gray-500 dark:text-gray-400">{t("no_lanes")}</p>
  }

  return (
    <div className="relative">
      <div ref={axisRef} style={{ touchAction: "none" }}>
        <TimeAxis scale={xScale} />
      </div>
      <div
        aria-label={t("lanes_aria")}
        className="relative h-[480px] overflow-y-auto overflow-x-hidden border-t border-gray-200 dark:border-gray-800"
        onScroll={onScroll}
        ref={scrollRef}
      >
        <div style={{ height: totalHeight, position: "relative" }}>
          {visibleLanes.map((lane, offset) => (
            <LaneRow
              index={startIndex + offset}
              key={`${lane.lane.key}:${lane.subrowIndex}`}
              lane={lane}
              onHover={setTooltip}
              onHoverRestart={setRestartTooltip}
              onSelectWorkflow={onSelectWorkflow}
              scale={xScale}
            />
          ))}
        </div>
      </div>
      {tooltip ? <SpanTooltip span={tooltip.span} x={tooltip.x} y={tooltip.y} /> : null}
      {restartTooltip ? <TooltipCard x={restartTooltip.x} y={restartTooltip.y}>{restartTooltip.text}</TooltipCard> : null}
    </div>
  )
}

function LaneRow({
  lane,
  index,
  scale,
  onHover,
  onHoverRestart,
  onSelectWorkflow
}: {
  lane: PackedLaneRow
  index: number
  scale: ScaleTime<number, number>
  onHover: (tooltip: TooltipState | null) => void
  onHoverRestart: (tooltip: RestartTooltipState | null) => void
  onSelectWorkflow: (workflowId: number) => void
}) {
  return (
    <div
      className="absolute left-0 right-0 flex items-center gap-2 border-b border-gray-100 dark:border-gray-800"
      style={{ top: index * ROW_HEIGHT, height: ROW_HEIGHT }}
    >
      <div className="w-40 shrink-0 truncate px-2 text-xs text-gray-600 dark:text-gray-400" title={`${lane.laneLabel} · ${lane.laneSecondaryLabel}`}>
        {lane.subrowIndex === 0 ? (
          <>
            <div className="truncate font-semibold text-gray-800 dark:text-gray-200">{lane.laneLabel}</div>
            <div className="truncate font-mono text-[11px] text-gray-500 dark:text-gray-500">{lane.laneSecondaryLabel}</div>
          </>
        ) : (
          <div className="flex min-w-0 items-center gap-1.5 text-[11px] text-gray-400 dark:text-gray-600">
            <span className="min-w-0 truncate font-semibold">{lane.laneLabel} ·</span>
            <span className="shrink-0 rounded border border-gray-200 px-1 font-mono dark:border-gray-800">{lane.subrowIndex + 1}/{lane.subrowCount}</span>
          </div>
        )}
      </div>
      <svg className="h-8 flex-1" preserveAspectRatio="none" role="img" viewBox={`0 0 ${CHART_WIDTH} 32`}>
        {lane.restartMarkers.map((marker) => {
          const x = scale(new Date(marker.timestamp))
          return (
            <g key={`${marker.timestamp}:${marker.label}`}>
              <line stroke="#64748b" strokeDasharray="3 3" strokeWidth="1.5" x1={x} x2={x} y1="3" y2="29" />
              <rect
                aria-label={marker.label}
                fill="transparent"
                height="32"
                onMouseEnter={(event) => onHoverRestart({ text: marker.label, x: event.clientX, y: event.clientY })}
                onMouseLeave={() => onHoverRestart(null)}
                onMouseMove={(event) => onHoverRestart({ text: marker.label, x: event.clientX, y: event.clientY })}
                role="img"
                width="10"
                x={x - 5}
                y="0"
              />
            </g>
          )
        })}
        {lane.spans.map((span) => {
          const x = scale(new Date(span.started_at))
          const endDate = span.finished_at ? new Date(span.finished_at) : new Date()
          const width = scale(endDate) - x
          return (
            <TimelineBar
              ariaLabel={span.label}
              fill={STATUS_COLORS[span.status] ?? "#94a3b8"}
              key={span.workflow_id}
              onClick={() => onSelectWorkflow(span.workflow_id)}
              onHover={(position) => {
                onHoverRestart(null)
                onHover(position ? { span, x: position.x, y: position.y } : null)
              }}
              width={width}
              x={x}
            />
          )
        })}
      </svg>
    </div>
  )
}

function SpanTooltip({ span, x, y }: { span: WorkerTimelineSpan; x: number; y: number }) {
  const { t } = useT("worker_timeline")
  const duration = formatDuration(span.started_at, span.finished_at)

  return (
    <TooltipCard x={x} y={y}>
      <p className="font-semibold">{span.label}</p>
      {span.job_title ? <p className="text-gray-700 dark:text-gray-200">{span.job_title}</p> : null}
      <p className="text-gray-500 dark:text-gray-400">{t("tooltip_workflow", { id: span.workflow_id })}</p>
      <p className="text-gray-500 dark:text-gray-400">{t("tooltip_host", { host: span.hostname ?? "?", start: span.started_at, end: span.finished_at ?? "now" })}</p>
      <p>{duration}</p>
      <p className="mt-1 text-gray-600 dark:text-gray-300">{blockedMessage(span.blocked, t)}</p>
    </TooltipCard>
  )
}

function buildPackedLaneRows(lanes: WorkerTimelineLane[], t: (key: string, options?: Record<string, unknown>) => string): PackedLaneRow[] {
  return lanes.flatMap((lane) => {
    const subrows = packSpans(lane.spans)
    const restartMarkers = restartMarkersFor(lane.spans, t)
    const laneLabel = lane.queue_role || t("unknown_queue_role")
    const laneSecondaryLabel = lane.worker_storage_key ? shortStorageKey(lane.worker_storage_key) : t("unknown_storage_key")

    return subrows.map((spans, subrowIndex) => ({
      lane,
      laneLabel,
      laneSecondaryLabel,
      subrowIndex,
      subrowCount: subrows.length,
      spans,
      restartMarkers
    }))
  })
}

function packSpans(spans: WorkerTimelineSpan[]) {
  const sorted = [ ...spans ].sort((a, b) => new Date(a.started_at).getTime() - new Date(b.started_at).getTime())
  const subrows: WorkerTimelineSpan[][] = []
  const subrowEnds: number[] = []

  sorted.forEach((span) => {
    const start = new Date(span.started_at).getTime()
    const end = span.finished_at ? new Date(span.finished_at).getTime() : Number.POSITIVE_INFINITY
    const rowIndex = subrowEnds.findIndex((lastEnd) => lastEnd <= start)

    if (rowIndex === -1) {
      subrows.push([ span ])
      subrowEnds.push(end)
    } else {
      subrows[rowIndex].push(span)
      subrowEnds[rowIndex] = end
    }
  })

  return subrows
}

function restartMarkersFor(spans: WorkerTimelineSpan[], t: (key: string, options?: Record<string, unknown>) => string) {
  const sorted = [ ...spans ].sort((a, b) => new Date(a.started_at).getTime() - new Date(b.started_at).getTime())
  const markers: RestartMarker[] = []

  sorted.forEach((span, index) => {
    if (index === 0) return

    const previous = sorted[index - 1]
    if (previous.pid === span.pid) return

    markers.push({
      timestamp: span.started_at,
      label: t("restart_marker_tooltip", { old_pid: previous.pid ?? "?", new_pid: span.pid ?? "?" })
    })
  })

  return markers
}

function shortStorageKey(storageKey: string) {
  if (storageKey.length <= 24) return storageKey

  return `${storageKey.slice(0, 10)}...${storageKey.slice(-10)}`
}
