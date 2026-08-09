import { forwardRef, type KeyboardEvent, type ReactNode } from "react"
import { useQuery } from "@tanstack/react-query"
import { Link } from "react-router-dom"
import { fetchJobDetail } from "../api/jobs"
import { useT } from "../hooks/useT"
import { Markdown } from "../lib/Markdown"
import { CopyableSlug } from "./CopyableSlug"
import { DeploymentStagePipeline } from "./DeploymentStagePipeline"
import { StartBlockedReasonPill } from "./StartBlockedReasonPill"
import { StatusPill } from "./StatusPill"

export function JobPreviewCard({ id, compact = false }: { id: number; compact?: boolean }) {
  const { t } = useT("jobs")
  const { data, isPending } = useQuery({
    queryKey: ["jobs", String(id)],
    queryFn: () => fetchJobDetail(String(id)),
    staleTime: 30_000,
  })

  if (isPending) return <JobPreviewSkeleton />
  if (!data) return null

  const { job } = data
  const body = job.issue_body ?? ""
  const truncatedBody = body.length > 500 ? body.slice(0, 500) + "…" : body
  const title = job.issue_title ?? (job.title_pending ? t("preview_generating_title") : "")

  return (
    <div className={compact ? "w-40 min-h-14 rounded-lg border border-gray-200 bg-white p-3 shadow-lg dark:border-gray-700 dark:bg-gray-900" : "w-80 rounded-lg border border-gray-200 bg-white p-4 shadow-lg dark:border-gray-700 dark:bg-gray-900"}>
      {!compact && data.deployment_stages?.length ? (
        <DeploymentStagePipeline stages={data.deployment_stages} />
      ) : null}
      <div className="mb-2 flex flex-wrap items-center gap-2">
        <CopyableSlug className="text-xs" slug={`JOB-${id}`} />
        <StatusPill state={job.state} />
        {job.state === "queued" && job.start_blocked_reason ? (
          <StartBlockedReasonPill details={job.start_blocked_details} reason={job.start_blocked_reason} />
        ) : null}
      </div>
      {title && (
        <Link
          to={`/jobs/${id}`}
          className={`mb-2 block text-sm font-medium text-gray-900 hover:underline dark:text-gray-100 ${compact ? "line-clamp-1" : "line-clamp-2"}`}
        >
          {title}
        </Link>
      )}
      {!compact && truncatedBody && (
        <div className="mb-3 line-clamp-6 text-xs text-gray-600 dark:text-gray-400 [&_code]:rounded [&_code]:bg-gray-100 [&_code]:px-0.5 [&_code]:font-mono dark:[&_code]:bg-gray-800 [&_h1]:font-semibold [&_h2]:font-semibold [&_h3]:font-semibold [&_pre]:rounded [&_pre]:bg-gray-100 [&_pre]:p-1.5 [&_pre]:font-mono dark:[&_pre]:bg-gray-800 [&_pre_code]:bg-transparent [&_pre_code]:px-0">
          <Markdown text={truncatedBody} />
        </div>
      )}
      {!compact && (
        <Link className="text-xs text-blue-600 hover:underline dark:text-blue-400" to={`/jobs/${id}`}>
          {t("preview_see_more")}
        </Link>
      )}
    </div>
  )
}

// Compact variant for use in graph/dependency views. Fixed width, 1-line
// title and state badge only — no data fetching required.
// Job labels from the backend follow "EPIC-N / source title" format;
// this variant extracts the source identifier (e.g. "#123" or "JOB-42")
// and the title from that structure.
// Epicless jobs (epicId === null) get a gray left accent.
export const JobCompactCard = forwardRef<
  HTMLDivElement,
  { label: string; state: string; epicId?: number | null; isFocal?: boolean; onClick?: () => void; renderSlug?: (slug: string) => ReactNode }
>(({ label, state, epicId = null, isFocal = false, onClick, renderSlug }, ref) => {
  const slashIdx = label.indexOf(" / ")
  const jobPart = slashIdx === -1 ? label : label.slice(slashIdx + 3)
  const spaceInJob = jobPart.indexOf(" ")
  const slug = spaceInJob === -1 ? jobPart : jobPart.slice(0, spaceInJob)
  const title = spaceInJob === -1 ? "" : jobPart.slice(spaceInJob + 1)
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
        epicId === null ? "border-l-4 border-l-gray-400 dark:border-l-gray-600" : "",
      ]
        .filter(Boolean)
        .join(" ")}
      data-testid="job-compact-card"
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
JobCompactCard.displayName = "JobCompactCard"

export function JobPreviewSkeleton() {
  return (
    <div className="w-80 animate-pulse rounded-lg border border-gray-200 bg-white p-4 shadow-lg dark:border-gray-700 dark:bg-gray-900">
      <div className="mb-2 flex items-center gap-2">
        <div className="h-3 w-12 rounded bg-gray-200 dark:bg-gray-700" />
        <div className="h-4 w-16 rounded-full bg-gray-200 dark:bg-gray-700" />
      </div>
      <div className="mb-3 space-y-1.5">
        <div className="h-4 w-full rounded bg-gray-200 dark:bg-gray-700" />
        <div className="h-4 w-3/4 rounded bg-gray-200 dark:bg-gray-700" />
      </div>
      <div className="space-y-1">
        <div className="h-3 w-full rounded bg-gray-200 dark:bg-gray-700" />
        <div className="h-3 w-full rounded bg-gray-200 dark:bg-gray-700" />
        <div className="h-3 w-2/3 rounded bg-gray-200 dark:bg-gray-700" />
      </div>
    </div>
  )
}
