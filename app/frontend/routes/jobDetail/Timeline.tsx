import { scaleTime } from "d3-scale"
import type { ScaleTime } from "d3-scale"
import { type ReactNode, useEffect, useState } from "react"
import { useQuery } from "@tanstack/react-query"
import { useT } from "../../hooks/useT"
import { Select } from "../../components/Select"
import { TimeAxis } from "../../components/timeline/TimeAxis"
import { TimelineBar } from "../../components/timeline/TimelineBar"
import { TooltipCard } from "../../components/timeline/TooltipCard"
import { fetchJobWaterfall, type JobWaterfallRun, type JobWaterfallStep, type JobWorkflow } from "../../api/jobs"
import { errorMessage } from "../../lib/errorMessage"
import { workflowSlug } from "../../lib/slugs"
import { formatDuration } from "./formatting"
import { PanelMessage } from "./components"

// Job detail page's Timeline tab: pick one of the Job's Workflows (reusing
// the same fetchJobWorkflows query the Workflows tab uses) and render its
// per-Step/Run waterfall from the non-admin-safe App::JobWaterfallPayload
// endpoint. Deliberately simpler than the worker_timeline plugin's
// WorkflowWaterfall -- a single ordered list of Steps, no lane-packing, no
// pan/zoom, no restart markers -- since this view only ever covers one
// Workflow at a time.

const CHART_WIDTH = 1000

const STATUS_COLORS: Record<string, string> = {
  queued: "#f59e0b",
  running: "#2563eb",
  succeeded: "#16a34a",
  failed: "#dc2626",
  cancelled: "#6b7280"
}

type TFunc = (key: string, options?: Record<string, unknown>) => string
type TooltipState = { x: number; y: number; content: ReactNode }

export function TimelineTab({
  jobId,
  workflows,
  loading = false,
  error = null
}: {
  jobId: string
  workflows: JobWorkflow[]
  loading?: boolean
  error?: unknown
}) {
  const { t } = useT("jobs")
  const [selectedWorkflowId, setSelectedWorkflowId] = useState<number | null>(null)

  useEffect(() => {
    if (workflows.length === 0) return
    if (selectedWorkflowId != null && workflows.some((workflow) => workflow.id === selectedWorkflowId)) return
    setSelectedWorkflowId(workflows[0].id)
  }, [workflows, selectedWorkflowId])

  if (loading) return <PanelMessage>{t("section_workflows_loading")}</PanelMessage>
  if (error) return <PanelMessage tone="error">{errorMessage(error, t("section_workflows_load_error"))}</PanelMessage>
  if (workflows.length === 0) return <PanelMessage>{t("section_no_workflows")}</PanelMessage>

  return (
    <div className="space-y-4">
      <label className="flex flex-wrap items-center gap-2 text-sm text-gray-600 dark:text-gray-300">
        {t("timeline_select_workflow")}
        <Select
          aria-label={t("timeline_select_workflow")}
          className="max-w-md"
          fullWidth={false}
          onChange={(event) => setSelectedWorkflowId(Number(event.target.value))}
          value={selectedWorkflowId ?? ""}
        >
          {workflows.map((workflow) => (
            <option key={workflow.id} value={workflow.id}>
              {workflowOptionLabel(workflow)}
            </option>
          ))}
        </Select>
      </label>
      {selectedWorkflowId != null ? <TimelineWaterfall jobId={jobId} workflowId={selectedWorkflowId} /> : null}
    </div>
  )
}

function workflowOptionLabel(workflow: JobWorkflow) {
  const started = workflow.started_at ? new Date(workflow.started_at).toLocaleString() : "not started"
  return `${workflowSlug(workflow.id)} · ${workflow.trigger_kind} · ${workflow.state} · ${started}`
}

function TimelineWaterfall({ jobId, workflowId }: { jobId: string; workflowId: number }) {
  const { t } = useT("jobs")
  const [tooltip, setTooltip] = useState<TooltipState | null>(null)
  const waterfall = useQuery({
    queryKey: ["jobs", jobId, "waterfall", workflowId],
    queryFn: () => fetchJobWaterfall(jobId, workflowId)
  })

  if (waterfall.isPending) return <PanelMessage>{t("timeline_waterfall_loading")}</PanelMessage>
  if (waterfall.isError) return <PanelMessage tone="error">{errorMessage(waterfall.error, t("timeline_waterfall_error"))}</PanelMessage>

  const { workflow, steps } = waterfall.data
  const hasStarted = Boolean(workflow.started_at)
  const from = workflow.started_at ?? workflow.finished_at ?? new Date().toISOString()
  const to = workflow.finished_at ?? new Date().toISOString()
  const xScale = scaleTime()
    .domain([new Date(from), new Date(to)])
    .range([0, CHART_WIDTH])

  function showTooltip(content: ReactNode, x: number, y: number) {
    setTooltip({ content, x, y })
  }

  function hideTooltip() {
    setTooltip(null)
  }

  return (
    <div className="relative space-y-3">
      <section
        aria-label={t("timeline_summary_aria")}
        className="rounded border border-gray-200 bg-white p-4 text-sm text-gray-700 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-300"
      >
        <p>{t("timeline_workflow_summary", { id: workflow.id, trigger_kind: workflow.trigger_kind, status: workflow.status })}</p>
        {workflow.hostname ? <p className="mt-1 text-xs text-gray-500 dark:text-gray-400">{t("timeline_ran_on_host", { host: workflow.hostname })}</p> : null}
        {!hasStarted ? <p className="mt-1 text-gray-500 dark:text-gray-400">{t("timeline_not_started_note")}</p> : null}
      </section>

      {steps.length === 0 ? (
        <PanelMessage>{t("timeline_no_steps")}</PanelMessage>
      ) : (
        <div className="rounded border border-gray-200 dark:border-gray-700">
          {hasStarted ? (
            <div className="border-b border-gray-200 px-2 pt-2 dark:border-gray-800">
              <TimeAxis scale={xScale} width={CHART_WIDTH} />
            </div>
          ) : null}
          <div aria-label={t("timeline_steps_aria")} className="divide-y divide-gray-100 dark:divide-gray-800">
            {steps.map((step) => (
              <StepRow
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
      )}

      {tooltip ? (
        <TooltipCard x={tooltip.x} y={tooltip.y}>
          {tooltip.content}
        </TooltipCard>
      ) : null}
    </div>
  )
}

function StepRow({
  step,
  scale,
  onHoverRun,
  onHoverStep,
  onLeaveTooltip,
  t
}: {
  step: JobWaterfallStep
  scale: ScaleTime<number, number>
  onHoverRun: (run: JobWaterfallRun, x: number, y: number) => void
  onHoverStep: (x: number, y: number) => void
  onLeaveTooltip: () => void
  t: TFunc
}) {
  const label = t("timeline_step_label", { kind: step.kind, iteration: step.iteration })
  const startedRuns = step.runs.filter((run) => run.started_at)

  return (
    <div className="flex items-center gap-2 px-2 py-2">
      <div className="w-48 shrink-0 truncate px-1 font-mono text-xs text-gray-600 dark:text-gray-400" title={label}>
        {label}
      </div>
      {startedRuns.length === 0 ? (
        <button
          className="rounded border border-gray-300 px-2 py-1 text-xs text-gray-500 dark:border-gray-600 dark:text-gray-400"
          onBlur={onLeaveTooltip}
          onFocus={(event) => onHoverStep(event.currentTarget.getBoundingClientRect().right, event.currentTarget.getBoundingClientRect().top)}
          onMouseEnter={(event) => onHoverStep(event.clientX, event.clientY)}
          onMouseLeave={onLeaveTooltip}
          onMouseMove={(event) => onHoverStep(event.clientX, event.clientY)}
          type="button"
        >
          {t("timeline_step_not_started")}
        </button>
      ) : (
        <svg className="h-8 flex-1" preserveAspectRatio="none" role="img" viewBox={`0 0 ${CHART_WIDTH} 32`}>
          {startedRuns.map((run) => {
            const x = scale(new Date(run.started_at as string))
            const endDate = run.finished_at ? new Date(run.finished_at) : new Date()
            const width = scale(endDate) - x
            return (
              <TimelineBar
                ariaLabel={t("timeline_run_label", { id: run.id, status: run.status })}
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

function runTooltipContent(run: JobWaterfallRun, t: TFunc): ReactNode {
  const duration = run.finished_at ? formatDuration(run.started_at, run.finished_at) : `${formatDuration(run.started_at, new Date().toISOString())}+`
  return (
    <>
      <p className="font-semibold">{t("timeline_run_tooltip_title", { id: run.id })}</p>
      <p className="text-gray-700 dark:text-gray-200">{run.status}</p>
      <p>{duration}</p>
    </>
  )
}

function stepTooltipContent(step: JobWaterfallStep, t: TFunc): ReactNode {
  return (
    <>
      <p className="font-semibold">{t("timeline_step_label", { kind: step.kind, iteration: step.iteration })}</p>
      <p className="text-gray-600 dark:text-gray-300">{t("timeline_step_not_started")}</p>
      {step.hostname ? <p className="mt-1 text-gray-600 dark:text-gray-300">{t("timeline_ran_on_host", { host: step.hostname })}</p> : null}
    </>
  )
}
