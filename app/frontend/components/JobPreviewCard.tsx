import { forwardRef, type KeyboardEvent, type ReactNode } from "react"
import { useQuery } from "@tanstack/react-query"
import { Link } from "react-router-dom"
import { fetchJobDetail, type JobDetailPayload, type JobRecord } from "../api/jobs"
import { useT } from "../hooks/useT"
import { entityHasFields, normalizeJobDetailPayload, useEntitySelector } from "../lib/entityStore"
import { renderLightMarkdown } from "../lib/Markdown"
import { Card, Skeleton } from "./Card"
import { CopyableSlug } from "./CopyableSlug"
import { DeploymentStagePipeline } from "./DeploymentStagePipeline"
import { StartBlockedReasonPill } from "./StartBlockedReasonPill"
import { StatusPill } from "./StatusPill"

export function JobPreviewCard({ id, compact = false }: { id: number; compact?: boolean }) {
  const { t } = useT("jobs")
  const cachedJob = useEntitySelector<JobRecord & { deployment_stages?: JobDetailPayload["deployment_stages"] }, JobPreviewFields | null>(
    "jobs",
    id,
    (entity) => entity ? previewFields(entity.fields) : null,
    shallowPreviewEqual
  )
  const hasPreviewFields = entityHasFields("jobs", id, PREVIEW_JOB_FIELDS)
  const { data, isPending } = useQuery({
    queryKey: ["jobs", String(id)],
    queryFn: async ({ signal }) => normalizeJobDetailPayload(await fetchJobDetail(String(id), "", { signal }), "job_preview"),
    enabled: !hasPreviewFields,
    staleTime: 30_000,
  })

  const job = cachedJob ?? (data ? previewFields({ ...data.job, deployment_stages: data.deployment_stages }) : null)

  if (!job && isPending) return <JobPreviewSkeleton />
  if (!job) return null

  const body = job.issue_body ?? ""
  const title = job.issue_title ?? (job.title_pending ? t("preview_generating_title") : "")

  return (
    <Card compact={compact} variant="preview">
      <div className="mb-2 flex flex-wrap items-center gap-2">
        <CopyableSlug className="text-xs" slug={`JOB-${id}`} />
        <StatusPill state={job.state} />
        {job.state === "queued" && job.start_blocked_reason ? (
          <StartBlockedReasonPill count={job.start_blocked_count} details={job.start_blocked_details} nextCheckAt={job.start_blocked_next_check_at} reason={job.start_blocked_reason} startBlockedAt={job.start_blocked_at} />
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
      {!compact && job.deployment_stages?.length ? (
        <DeploymentStagePipeline stages={job.deployment_stages} />
      ) : null}
      {!compact && body && (
        <div className="mb-3 line-clamp-6 break-words text-xs text-gray-600 dark:text-gray-400">
          {renderLightMarkdown(body)}
        </div>
      )}
      {!compact && (
        <Link className="text-xs text-brand hover:underline dark:text-brand-emphasis" to={`/jobs/${id}`}>
          {t("preview_see_more")}
        </Link>
      )}
    </Card>
  )
}

const PREVIEW_JOB_FIELDS = [
  "state",
  "start_blocked_reason",
  "start_blocked_count",
  "start_blocked_details",
  "start_blocked_next_check_at",
  "start_blocked_at",
  "issue_title",
  "title_pending",
  "issue_body"
] as const

type JobPreviewFields = Pick<
  JobRecord,
  | "state"
  | "start_blocked_reason"
  | "start_blocked_count"
  | "start_blocked_details"
  | "start_blocked_next_check_at"
  | "start_blocked_at"
  | "issue_title"
  | "title_pending"
  | "issue_body"
> & {
  deployment_stages?: JobDetailPayload["deployment_stages"]
}

function previewFields(job: Partial<JobRecord> & { deployment_stages?: JobDetailPayload["deployment_stages"] }): JobPreviewFields {
  return {
    state: job.state ?? "unknown",
    start_blocked_reason: job.start_blocked_reason ?? null,
    start_blocked_count: job.start_blocked_count ?? null,
    start_blocked_details: job.start_blocked_details ?? null,
    start_blocked_next_check_at: job.start_blocked_next_check_at ?? null,
    start_blocked_at: job.start_blocked_at ?? null,
    issue_title: job.issue_title ?? null,
    title_pending: job.title_pending ?? false,
    issue_body: job.issue_body ?? null,
    deployment_stages: job.deployment_stages
  }
}

function shallowPreviewEqual(left: JobPreviewFields | null, right: JobPreviewFields | null) {
  if (left === right) return true
  if (!left || !right) return false

  return PREVIEW_JOB_FIELDS.every((field) => left[field] === right[field]) && left.deployment_stages === right.deployment_stages
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
    <Card variant="preview">
      <div className="mb-2 flex items-center gap-2">
        <Skeleton className="h-3 w-12" />
        <Skeleton className="h-4 w-16 rounded-full" />
      </div>
      <div className="mb-3 space-y-1.5">
        <Skeleton className="h-4 w-full" />
        <Skeleton className="h-4 w-3/4" />
      </div>
      <div className="space-y-1">
        <Skeleton className="h-3 w-full" />
        <Skeleton className="h-3 w-full" />
        <Skeleton className="h-3 w-2/3" />
      </div>
    </Card>
  )
}
