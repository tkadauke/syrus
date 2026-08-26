import { useT } from "../hooks/useT"
import type { JobDeploymentStage } from "../api/jobs"
import type { EpicDeploymentStage } from "../api/epics"
import { RelativeTimestamp } from "./RelativeTimestamp"

type StageFillState = "reached" | "partial" | "pending"

function StageCircle({ state }: { state: StageFillState }) {
  if (state === "reached") {
    return (
      <span className="inline-flex h-5 w-5 shrink-0 items-center justify-center rounded-full border border-emerald-200 bg-emerald-100 text-2xs font-semibold text-emerald-700 dark:border-emerald-800 dark:bg-emerald-950 dark:text-emerald-300">
        ✓
      </span>
    )
  }

  if (state === "partial") {
    return (
      <span aria-hidden="true" className="relative inline-flex h-5 w-5 shrink-0 items-center justify-center overflow-hidden rounded-full border border-emerald-200 bg-gray-100 dark:border-emerald-800 dark:bg-gray-900">
        <span className="absolute inset-y-0 left-0 w-1/2 bg-emerald-500 dark:bg-emerald-600" />
      </span>
    )
  }

  return <span className="inline-flex h-5 w-5 shrink-0 items-center justify-center rounded-full border border-gray-300 bg-gray-100 text-2xs font-semibold text-gray-400 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-500" />
}

function StageConnector({ filled }: { filled: boolean }) {
  return (
    <span aria-hidden="true" className="mx-1 h-0.5 flex-1 overflow-hidden rounded bg-gray-200 dark:bg-gray-800">
      <span className={`block h-full ${filled ? "bg-emerald-500" : "bg-transparent"}`} />
    </span>
  )
}

export function DeploymentStagePipeline({ stages }: { stages: JobDeploymentStage[] }) {
  const { t } = useT("jobs")

  return (
    <div aria-label={t("deployment_stages_label")} className="mt-3 pb-1">
      <ol className="flex w-full" data-testid="deployment-stage-pipeline">
        {stages.map((stage, index) => {
          const reached = Boolean(stage.reached_at)
          const nextReached = Boolean(stages[index + 1]?.reached_at)
          return (
            <li className="flex min-w-0 flex-1 flex-col gap-1" data-reached={reached ? "true" : "false"} key={stage.name}>
              <div className="flex items-center">
                <StageCircle state={reached ? "reached" : "pending"} />
                {index < stages.length - 1 ? <StageConnector filled={reached && nextReached} /> : null}
              </div>
              <span className="w-full break-words text-xs font-medium text-gray-800 dark:text-gray-100">{stage.label}</span>
              <span className={`text-xs ${reached ? "text-emerald-700 dark:text-emerald-300" : "text-gray-400 dark:text-gray-500"}`}>
                {reached ? <RelativeTimestamp value={stage.reached_at} /> : t("deployment_stage_pending")}
              </span>
            </li>
          )
        })}
      </ol>
    </div>
  )
}

// Epic-level view of the same pipeline: each stage aggregates every landed
// child Job. Jobs usually agree, so a stage renders exactly like the Job
// detail pipeline (a full circle once every Job has reached it). When Jobs
// disagree — some landed on staging, others already in production — the
// stage renders as a half-filled circle instead of picking a side.
export function EpicDeploymentStagePipeline({ stages }: { stages: EpicDeploymentStage[] }) {
  const { t } = useT("epics")

  return (
    <div aria-label={t("deployment_stages_label")} className="mt-3 pb-1">
      <ol className="flex w-full" data-testid="epic-deployment-stage-pipeline">
        {stages.map((stage, index) => {
          const state: StageFillState = stage.total <= 0 || stage.reached_count <= 0
            ? "pending"
            : stage.reached_count >= stage.total ? "reached" : "partial"
          const nextStage = stages[index + 1]
          const nextReached = Boolean(nextStage && nextStage.total > 0 && nextStage.reached_count >= nextStage.total)
          return (
            <li className="flex min-w-0 flex-1 flex-col gap-1" data-state={state} key={stage.name}>
              <div className="flex items-center">
                <StageCircle state={state} />
                {index < stages.length - 1 ? <StageConnector filled={state === "reached" && nextReached} /> : null}
              </div>
              <span className="w-full break-words text-xs font-medium text-gray-800 dark:text-gray-100">{stage.label}</span>
              <span className={`text-xs ${state === "reached" ? "text-emerald-700 dark:text-emerald-300" : state === "partial" ? "text-amber-700 dark:text-amber-300" : "text-gray-400 dark:text-gray-500"}`}>
                {state === "reached" && stage.reached_at ? (
                  <RelativeTimestamp value={stage.reached_at} />
                ) : state === "partial" ? (
                  t("deployment_stage_partial", { reached: stage.reached_count, total: stage.total })
                ) : (
                  t("deployment_stage_pending")
                )}
              </span>
            </li>
          )
        })}
      </ol>
    </div>
  )
}
