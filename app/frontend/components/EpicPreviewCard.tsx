import { forwardRef, type KeyboardEvent, type ReactNode } from "react"
import { useQuery } from "@tanstack/react-query"
import { Link } from "react-router-dom"
import type { EpicDeploymentStage, EpicDetailJob } from "../api/epics"
import { fetchEpicDetail } from "../api/epics"
import { useT } from "../hooks/useT"
import { CopyableSlug } from "./CopyableSlug"
import { RelativeTimestamp } from "./RelativeTimestamp"
import { StatusPill } from "./StatusPill"

const PROGRESS_SEGMENTS = [
  { state: "merged", color: "bg-emerald-700" },
  { state: "approved", color: "bg-green-500" },
  { state: "implemented", color: "bg-cyan-500" },
  { state: "blocked_by_epic", color: "bg-amber-400" },
]

// Lower number = more urgent / shown first
const ATTENTION_ORDER: Record<string, number> = {
  failed: 0,
  landing_failed: 0,
  blocked_by_epic: 1,
  triaging: 2,
  open: 3,
  running: 3,
  implemented: 4,
  approved: 5,
  landing: 5,
  merged: 6,
  closed: 7,
  preempted: 7,
}

function attentionPriority(state: string): number {
  return ATTENTION_ORDER[state] ?? 3
}

function EpicDeploymentStagesRow({ stages }: { stages: EpicDeploymentStage[] }) {
  const { t } = useT("epics")

  return (
    <div aria-label={t("deployment_stages_label")} className="mb-3">
      <ol className="flex w-full items-start" data-testid="epic-deployment-stage-pipeline">
        {stages.map((stage, index) => {
          const fullyReached = stage.reached_count === stage.total
          const partiallyReached = stage.reached_count > 0
          return (
            <li className="flex min-w-0 flex-1 items-start" key={stage.name}>
              <div className="flex min-w-0 flex-1 flex-col items-start gap-1">
                <span className={`inline-flex h-5 min-w-5 items-center justify-center rounded-full border px-1 text-[11px] font-semibold ${fullyReached ? "border-emerald-200 bg-emerald-100 text-emerald-700 dark:border-emerald-800 dark:bg-emerald-950 dark:text-emerald-300" : partiallyReached ? "border-amber-200 bg-amber-50 text-amber-700 dark:border-amber-800 dark:bg-amber-950 dark:text-amber-300" : "border-gray-300 bg-gray-100 text-gray-400 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-500"}`}>
                  {fullyReached ? "✓" : `${stage.reached_count}/${stage.total}`}
                </span>
                <span className="w-full break-words text-xs font-medium text-gray-800 dark:text-gray-100">{stage.label}</span>
                {stage.reached_at ? (
                  <span className={`text-xs ${fullyReached ? "text-emerald-700 dark:text-emerald-300" : "text-amber-700 dark:text-amber-300"}`}>
                    <RelativeTimestamp value={stage.reached_at} />
                  </span>
                ) : null}
              </div>
              {index < stages.length - 1 ? (
                <span className="mt-2.5 h-0.5 w-8 shrink-0 overflow-hidden rounded bg-gray-200 dark:bg-gray-800" aria-hidden="true">
                  <span className={`block h-full ${fullyReached && stages[index + 1]?.reached_count === stages[index + 1]?.total ? "bg-emerald-500" : "bg-transparent"}`} />
                </span>
              ) : null}
            </li>
          )
        })}
      </ol>
    </div>
  )
}

export function EpicPreviewCard({ id, compact = false }: { id: number; compact?: boolean }) {
  const { t } = useT("epics")
  const { data, isPending } = useQuery({
    queryKey: ["epics", String(id)],
    queryFn: () => fetchEpicDetail(String(id)),
    staleTime: 30_000,
  })

  if (isPending) return <EpicPreviewSkeleton />
  if (!data) return null

  const { epic, jobs } = data
  const description = epic.description ?? ""
  const truncatedDesc = description.length > 500 ? description.slice(0, 500) + "…" : description
  const totalCount = epic.jobs_count

  const sortedJobs = [...jobs].sort((a, b) => attentionPriority(a.state) - attentionPriority(b.state))
  const previewJobs = sortedJobs.slice(0, 5)

  return (
    <div className={compact ? "w-40 min-h-14 rounded-lg border border-gray-200 bg-white p-3 shadow-lg dark:border-gray-700 dark:bg-gray-900" : "w-80 rounded-lg border border-gray-200 bg-white p-4 shadow-lg dark:border-gray-700 dark:bg-gray-900"}>
      {!compact && data.deployment_stages?.length ? (
        <EpicDeploymentStagesRow stages={data.deployment_stages} />
      ) : null}
      <div className="mb-2 flex items-center gap-2">
        <CopyableSlug className="text-xs" slug={epic.display_number} />
        <StatusPill state={epic.state} />
      </div>
      <Link className={`mb-2 block text-sm font-medium text-gray-900 hover:underline dark:text-gray-100 ${compact ? "line-clamp-1" : "line-clamp-2"}`} to={`/epics/${id}`}>
        {epic.title}
      </Link>
      {!compact && totalCount > 0 && (
        <div
          aria-label={t("job_progress_label")}
          className="mb-3 flex h-1.5 w-full overflow-hidden rounded-full bg-gray-200 dark:bg-gray-700"
          role="progressbar"
        >
          {PROGRESS_SEGMENTS.map(({ state, color }) => {
            const count = jobs.filter((j) => j.state === state).length
            const percent = (count / totalCount) * 100
            return percent > 0 ? (
              <div className={`h-1.5 transition-[width] ${color}`} key={state} style={{ width: `${percent}%` }} />
            ) : null
          })}
        </div>
      )}
      {!compact && truncatedDesc && (
        <p className="mb-3 line-clamp-4 whitespace-pre-wrap text-xs text-gray-600 dark:text-gray-400">
          {truncatedDesc}
        </p>
      )}
      {!compact && previewJobs.length > 0 && (
        <ul className="mb-3 space-y-1">
          {previewJobs.map((job: EpicDetailJob) => (
            <li key={job.id}>
              <Link
                className="flex min-w-0 items-center gap-2 rounded text-xs text-gray-700 hover:bg-gray-50 dark:text-gray-300 dark:hover:bg-gray-800"
                to={`/jobs/${job.id}`}
              >
                <StatusPill state={job.state} />
                <span className="truncate">{job.title}</span>
              </Link>
            </li>
          ))}
        </ul>
      )}
      {!compact && (
        <Link className="text-xs text-blue-600 hover:underline dark:text-blue-400" to={`/epics/${id}`}>
          {t("preview_see_more")}
        </Link>
      )}
    </div>
  )
}

// Compact variant for use in graph/dependency views. Fixed width, 1-line
// title and state badge only — no data fetching required.
export const EpicCompactCard = forwardRef<
  HTMLDivElement,
  { label: string; state: string; isFocal?: boolean; onClick?: () => void; renderSlug?: (slug: string) => ReactNode }
>(({ label, state, isFocal = false, onClick, renderSlug }, ref) => {
  const spaceIdx = label.indexOf(" ")
  const slug = spaceIdx === -1 ? label : label.slice(0, spaceIdx)
  const title = spaceIdx === -1 ? "" : label.slice(spaceIdx + 1)
  const interactiveProps = onClick ? {
    "aria-label": label,
    onKeyDown: (event: KeyboardEvent<HTMLDivElement>) => {
      if (event.target !== event.currentTarget) return
      if (event.key === "Enter" || event.key === " ") {
        event.preventDefault()
        onClick()
      }
    },
    role: "link",
    tabIndex: 0,
  } : {}

  return (
    <div
      className={[
        "w-48 cursor-pointer rounded-lg border bg-white p-3 text-left shadow-sm transition-shadow hover:shadow-md dark:bg-gray-900",
        isFocal
          ? "border-gray-900 ring-2 ring-gray-900 dark:border-gray-100 dark:ring-gray-100"
          : "border-gray-200 dark:border-gray-700",
      ].join(" ")}
      data-testid="epic-compact-card"
      onClick={onClick}
      ref={ref}
      {...interactiveProps}
    >
      <div className="mb-1 flex items-center gap-1.5 overflow-hidden">
        {renderSlug ? renderSlug(slug) : <span className="shrink-0 font-mono text-xs text-gray-500 dark:text-gray-400">{slug}</span>}
        <StatusPill state={state} />
      </div>
      {title && <p className="truncate text-xs text-gray-700 dark:text-gray-300">{title}</p>}
    </div>
  )
})
EpicCompactCard.displayName = "EpicCompactCard"

export function EpicPreviewSkeleton() {
  return (
    <div className="w-80 animate-pulse rounded-lg border border-gray-200 bg-white p-4 shadow-lg dark:border-gray-700 dark:bg-gray-900">
      <div className="mb-2 flex items-center gap-2">
        <div className="h-3 w-16 rounded bg-gray-200 dark:bg-gray-700" />
        <div className="h-4 w-20 rounded-full bg-gray-200 dark:bg-gray-700" />
      </div>
      <div className="mb-2">
        <div className="h-4 w-3/4 rounded bg-gray-200 dark:bg-gray-700" />
      </div>
      <div className="mb-3 h-1.5 w-full rounded-full bg-gray-200 dark:bg-gray-700" />
      <div className="mb-3 space-y-1">
        <div className="h-3 w-full rounded bg-gray-200 dark:bg-gray-700" />
        <div className="h-3 w-full rounded bg-gray-200 dark:bg-gray-700" />
        <div className="h-3 w-2/3 rounded bg-gray-200 dark:bg-gray-700" />
      </div>
    </div>
  )
}
