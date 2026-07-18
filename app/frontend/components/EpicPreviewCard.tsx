import { useQuery } from "@tanstack/react-query"
import { Link } from "react-router-dom"
import type { EpicDetailJob } from "../api/epics"
import { fetchEpicDetail } from "../api/epics"
import { useT } from "../hooks/useT"
import { CopyableSlug } from "./CopyableSlug"
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

export function EpicPreviewCard({ id }: { id: number }) {
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
    <div className="w-80 rounded-lg border border-gray-200 bg-white p-4 shadow-lg dark:border-gray-700 dark:bg-gray-900">
      <div className="mb-2 flex items-center gap-2">
        <CopyableSlug className="text-xs" slug={epic.display_number} />
        <StatusPill state={epic.state} />
      </div>
      <p className="mb-2 text-sm font-medium text-gray-900 dark:text-gray-100">{epic.title}</p>
      {totalCount > 0 && (
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
      {truncatedDesc && (
        <p className="mb-3 line-clamp-4 whitespace-pre-wrap text-xs text-gray-600 dark:text-gray-400">
          {truncatedDesc}
        </p>
      )}
      {previewJobs.length > 0 && (
        <ul className="mb-3 space-y-1">
          {previewJobs.map((job: EpicDetailJob) => (
            <li className="flex min-w-0 items-center gap-2 text-xs text-gray-700 dark:text-gray-300" key={job.id}>
              <StatusPill state={job.state} />
              <span className="truncate">{job.title}</span>
            </li>
          ))}
        </ul>
      )}
      <Link className="text-xs text-blue-600 hover:underline dark:text-blue-400" to={`/epics/${id}`}>
        {t("preview_see_more")}
      </Link>
    </div>
  )
}

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
