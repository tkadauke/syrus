import type { ScaleTime } from "d3-scale"
import { type ReactNode, useState } from "react"
import { useT } from "@app/hooks/useT"
import type { WorkerTimelineWaterfallPayload, WorkerTimelineWaterfallRun, WorkerTimelineWaterfallStep } from "../api/workerTimeline"
import { CHART_WIDTH, ROW_HEIGHT, STATUS_COLORS } from "./timeline/constants"
import { TimeAxis } from "./timeline/TimeAxis"
import { TimelineBar } from "./timeline/TimelineBar"
import { TooltipCard } from "./timeline/TooltipCard"
import { blockedMessage, formatDuration } from "./timeline/spanFormatting"
import { useVirtualizedRows } from "./timeline/useVirtualizedRows"
import { useZoomableTimeScale } from "./timeline/useZoomableTimeScale"

type TFunc = (key: string, options?: Record<string, unknown>) => string

type TooltipState = { x: number; y: number; content: ReactNode }

// Per-workflow drill-down waterfall: one lane per Step (in position
// order), with that Step's Run attempt(s) drawn as spans within the lane
// so retries are visible. Reuses the macro (TimelineLanes) view's
// bar/pan-zoom/tooltip primitives from ./timeline rather than
// reimplementing them.
export function WorkflowWaterfall({ payload }: { payload: WorkerTimelineWaterfallPayload }) {
  const { t } = useT("worker_timeline")
  const { workflow, steps } = payload
  const [tooltip, setTooltip] = useState<TooltipState | null>(null)

  const hasStarted = Boolean(workflow.started_at)
  const from = workflow.started_at ?? workflow.finished_at ?? new Date().toISOString()
  const to = workflow.finished_at ?? new Date().toISOString()

  const { axisRef, xScale } = useZoomableTimeScale(from, to)
  const { scrollRef, startIndex, endIndex, totalHeight, onScroll } = useVirtualizedRows(steps.length, ROW_HEIGHT)
  const visibleSteps = steps.slice(startIndex, endIndex)

  function showTooltip(content: ReactNode, x: number, y: number) {
    setTooltip({ content, x, y })
  }

  function hideTooltip() {
    setTooltip(null)
  }

  return (
    <div className="space-y-4">
      <section aria-label={t("detail_summary_aria")} className="rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 p-4 text-sm text-gray-700 dark:text-gray-300">
        <p>{t("detail_summary", { id: workflow.id, trigger_kind: workflow.trigger_kind, status: workflow.status })}</p>
        {!hasStarted ? <p className="mt-1 text-gray-500 dark:text-gray-400">{t("detail_not_started_note")}</p> : null}
      </section>

      {steps.length === 0 ? (
        <p className="p-6 text-sm text-gray-500 dark:text-gray-400">{t("detail_no_steps")}</p>
      ) : (
        <div className="relative">
          {hasStarted ? (
            <div ref={axisRef} style={{ touchAction: "none" }}>
              <TimeAxis scale={xScale} />
            </div>
          ) : null}
          <div
            aria-label={t("detail_steps_aria")}
            className="relative h-[480px] overflow-y-auto overflow-x-hidden border-t border-gray-200 dark:border-gray-800"
            onScroll={onScroll}
            ref={scrollRef}
          >
            <div style={{ height: totalHeight, position: "relative" }}>
              {visibleSteps.map((step, offset) => (
                <StepRow
                  index={startIndex + offset}
                  key={step.id}
                  onHoverRun={(run, x, y) => showTooltip(runTooltipContent(run, t), x, y)}
                  onHoverStep={(x, y) => showTooltip(stepTooltipContent(step, t), x, y)}
                  onLeaveTooltip={hideTooltip}
                  scale={xScale}
                  step={step}
                  t={t}
                />
              ))}
            </div>
          </div>
        </div>
      )}

      {tooltip ? <TooltipCard x={tooltip.x} y={tooltip.y}>{tooltip.content}</TooltipCard> : null}
    </div>
  )
}

function StepRow({
  step,
  index,
  scale,
  onHoverRun,
  onHoverStep,
  onLeaveTooltip,
  t
}: {
  step: WorkerTimelineWaterfallStep
  index: number
  scale: ScaleTime<number, number>
  onHoverRun: (run: WorkerTimelineWaterfallRun, x: number, y: number) => void
  onHoverStep: (x: number, y: number) => void
  onLeaveTooltip: () => void
  t: TFunc
}) {
  const label = t("detail_step_label", { kind: step.kind, iteration: step.iteration })
  const startedRuns = step.runs.filter((run) => run.started_at)

  return (
    <div
      className="absolute left-0 right-0 flex items-center gap-2 border-b border-gray-100 dark:border-gray-800"
      style={{ top: index * ROW_HEIGHT, height: ROW_HEIGHT }}
    >
      <div className="w-48 shrink-0 truncate px-2 font-mono text-xs text-gray-600 dark:text-gray-400" title={label}>
        {label}
      </div>
      {startedRuns.length === 0 ? (
        <button
          className="rounded border border-gray-300 dark:border-gray-600 px-2 py-1 text-xs text-gray-500 dark:text-gray-400"
          onBlur={onLeaveTooltip}
          onFocus={(event) => onHoverStep(event.currentTarget.getBoundingClientRect().right, event.currentTarget.getBoundingClientRect().top)}
          onMouseEnter={(event) => onHoverStep(event.clientX, event.clientY)}
          onMouseLeave={onLeaveTooltip}
          onMouseMove={(event) => onHoverStep(event.clientX, event.clientY)}
          type="button"
        >
          {t("detail_step_not_started")}
        </button>
      ) : (
        <svg className="h-8 flex-1" preserveAspectRatio="none" role="img" viewBox={`0 0 ${CHART_WIDTH} 32`}>
          {startedRuns.map((run) => {
            const x = scale(new Date(run.started_at as string))
            const endDate = run.finished_at ? new Date(run.finished_at) : new Date()
            const width = scale(endDate) - x
            return (
              <TimelineBar
                ariaLabel={t("detail_run_label", { id: run.id, status: run.status })}
                fill={STATUS_COLORS[run.status] ?? "#94a3b8"}
                key={run.id}
                onHover={(position) => (position ? onHoverRun(run, position.x, position.y) : onLeaveTooltip())}
                width={width}
                x={x}
              />
            )
          })}
        </svg>
      )}
    </div>
  )
}

function runTooltipContent(run: WorkerTimelineWaterfallRun, t: TFunc): ReactNode {
  const duration = formatDuration(run.started_at as string, run.finished_at)
  return (
    <>
      <p className="font-semibold">{t("detail_run_tooltip_title", { id: run.id })}</p>
      <p className="text-gray-700 dark:text-gray-200">{run.status}</p>
      <p>{duration}</p>
    </>
  )
}

function stepTooltipContent(step: WorkerTimelineWaterfallStep, t: TFunc): ReactNode {
  return (
    <>
      <p className="font-semibold">{t("detail_step_label", { kind: step.kind, iteration: step.iteration })}</p>
      <p className="text-gray-600 dark:text-gray-300">{t("detail_step_not_started")}</p>
      {step.blocked ? <p className="mt-1 text-gray-600 dark:text-gray-300">{blockedMessage(step.blocked, t)}</p> : null}
    </>
  )
}
