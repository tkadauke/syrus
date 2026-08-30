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

export function TimelineLanes({
  payload,
  onSelectWorkflow
}: {
  payload: WorkerTimelineMacroPayload
  onSelectWorkflow: (workflowId: number) => void
}) {
  const { t } = useT("worker_timeline")
  const [tooltip, setTooltip] = useState<TooltipState | null>(null)

  const lanes = payload.lanes

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
              key={lane.key}
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
          const width = scale(endDate) - x
          return (
            <TimelineBar
              ariaLabel={span.label}
              fill={STATUS_COLORS[span.status] ?? "#94a3b8"}
              key={span.workflow_id}
              onClick={() => onSelectWorkflow(span.workflow_id)}
              onHover={(position) => onHover(position ? { span, x: position.x, y: position.y } : null)}
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
      <p>{duration}</p>
      <p className="mt-1 text-gray-600 dark:text-gray-300">{blockedMessage(span.blocked, t)}</p>
    </TooltipCard>
  )
}
