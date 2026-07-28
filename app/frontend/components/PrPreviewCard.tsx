import { useQuery } from "@tanstack/react-query"
import { Link } from "react-router-dom"
import { fetchJobDetail } from "../api/jobs"
import { useT } from "../hooks/useT"
import { MergeablePill } from "../routes/jobDetail/components"
import { CopyableSlug } from "./CopyableSlug"
import { RelativeTimestamp } from "./RelativeTimestamp"
import { StatusPill } from "./StatusPill"

function ExternalLinkIcon({ className = "" }: { className?: string }) {
  return (
    <svg aria-hidden="true" className={className} fill="none" stroke="currentColor" strokeWidth="2" viewBox="0 0 24 24">
      <path d="M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6" strokeLinecap="round" strokeLinejoin="round" />
      <polyline points="15 3 21 3 21 9" strokeLinecap="round" strokeLinejoin="round" />
      <line strokeLinecap="round" strokeLinejoin="round" x1="10" x2="21" y1="14" y2="3" />
    </svg>
  )
}

export function PrPreviewCard({ jobId, prNumber, prUrl }: { jobId: number; prNumber: number; prUrl: string }) {
  const { t } = useT("jobs")
  const { data, isPending } = useQuery({
    queryKey: ["jobs", String(jobId)],
    queryFn: () => fetchJobDetail(String(jobId)),
    staleTime: 30_000,
  })

  if (!prUrl) return null
  if (isPending) return <PrPreviewSkeleton />
  if (!data) return null

  const { job } = data
  const title = job.issue_title ?? (job.title_pending ? t("preview_generating_title") : "")
  const truncatedTitle = title.length > 120 ? title.slice(0, 120) + "…" : title

  return (
    <div className="w-80 rounded-lg border border-gray-200 bg-white p-4 shadow-lg dark:border-gray-700 dark:bg-gray-900">
      <div className="mb-3 flex items-center gap-2">
        <CopyableSlug className="text-xs" slug={`PR #${prNumber}`} />
        <a
          aria-label={`Open PR #${prNumber} on GitHub`}
          className="text-gray-400 hover:text-blue-600 dark:text-gray-500 dark:hover:text-blue-400"
          href={prUrl}
          rel="noopener noreferrer"
          target="_blank"
        >
          <ExternalLinkIcon className="h-3.5 w-3.5" />
        </a>
        <StatusPill state={job.state} />
      </div>
      {truncatedTitle && (
        <Link className="mb-3 block text-sm text-gray-900 hover:underline dark:text-gray-100" to={`/jobs/${jobId}`}>
          {truncatedTitle}
        </Link>
      )}
      <div className="flex items-center gap-2 text-xs text-gray-500 dark:text-gray-400">
        <MergeablePill value={job.pr_mergeable} />
        {job.pr_mergeable_checked_at && (
          <RelativeTimestamp value={job.pr_mergeable_checked_at} />
        )}
      </div>
    </div>
  )
}

export function PrPreviewSkeleton() {
  return (
    <div className="w-80 animate-pulse rounded-lg border border-gray-200 bg-white p-4 shadow-lg dark:border-gray-700 dark:bg-gray-900">
      <div className="mb-3 flex items-center gap-2">
        <div className="h-3 w-16 rounded bg-gray-200 dark:bg-gray-700" />
        <div className="h-3.5 w-3.5 rounded bg-gray-200 dark:bg-gray-700" />
        <div className="h-4 w-16 rounded-full bg-gray-200 dark:bg-gray-700" />
      </div>
      <div className="mb-3 space-y-1.5">
        <div className="h-4 w-full rounded bg-gray-200 dark:bg-gray-700" />
        <div className="h-4 w-3/4 rounded bg-gray-200 dark:bg-gray-700" />
      </div>
      <div className="flex items-center gap-2">
        <div className="h-4 w-20 rounded-full bg-gray-200 dark:bg-gray-700" />
        <div className="h-3 w-24 rounded bg-gray-200 dark:bg-gray-700" />
      </div>
    </div>
  )
}
