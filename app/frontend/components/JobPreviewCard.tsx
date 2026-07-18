import { useQuery } from "@tanstack/react-query"
import { Link } from "react-router-dom"
import { fetchJobDetail } from "../api/jobs"
import { useT } from "../hooks/useT"
import { CopyableSlug } from "./CopyableSlug"
import { StatusPill } from "./StatusPill"

export function JobPreviewCard({ id }: { id: number }) {
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
    <div className="w-80 rounded-lg border border-gray-200 bg-white p-4 shadow-lg dark:border-gray-700 dark:bg-gray-900">
      <div className="mb-2 flex items-center gap-2">
        <CopyableSlug className="text-xs" slug={`JOB-${id}`} />
        <StatusPill state={job.state} />
      </div>
      {title && <p className="mb-2 text-sm font-medium text-gray-900 dark:text-gray-100">{title}</p>}
      {truncatedBody && (
        <p className="mb-3 line-clamp-6 whitespace-pre-wrap text-xs text-gray-600 dark:text-gray-400">
          {truncatedBody}
        </p>
      )}
      <Link className="text-xs text-blue-600 hover:underline dark:text-blue-400" to={`/jobs/${id}`}>
        {t("preview_see_more")}
      </Link>
    </div>
  )
}

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
