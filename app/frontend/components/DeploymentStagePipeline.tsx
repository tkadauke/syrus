import { useT } from "../hooks/useT"
import type { JobDeploymentStage } from "../api/jobs"
import { RelativeTimestamp } from "./RelativeTimestamp"

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
                <span className={`inline-flex h-5 w-5 shrink-0 items-center justify-center rounded-full border text-[11px] font-semibold ${reached ? "border-emerald-200 bg-emerald-100 text-emerald-700 dark:border-emerald-800 dark:bg-emerald-950 dark:text-emerald-300" : "border-gray-300 bg-gray-100 text-gray-400 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-500"}`}>
                  {reached ? "✓" : ""}
                </span>
                {index < stages.length - 1 ? (
                  <span className="mx-1 h-0.5 flex-1 overflow-hidden rounded bg-gray-200 dark:bg-gray-800" aria-hidden="true">
                    <span className={`block h-full ${reached && nextReached ? "bg-emerald-500" : "bg-transparent"}`} />
                  </span>
                ) : null}
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
