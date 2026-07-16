import { useQuery, useQueryClient } from "@tanstack/react-query"
import { useEffect, useState } from "react"
import { useNavigate } from "react-router-dom"
import type { ChatJobStatusBlocker, ChatJobStatusEpicItem, ChatJobStatusItem, ChatJobStatusJobItem } from "../api/chats"
import { fetchChatJobStatus } from "../api/chats"
import { useT } from "../hooks/useT"
import { StatusPill } from "../components/StatusPill"

function jobBorderClass(job: ChatJobStatusJobItem): string {
  if (job.blocker) return "border-l-red-500"

  const s = job.state
  if (s === "pr_merged" || s === "external_pr_merged" || s === "no_changes") return "border-l-emerald-500"
  if (s === "implemented" || s === "approved" || s === "landing") return "border-l-amber-400"
  if (s === "open" || s === "coding") return "border-l-blue-500"
  return "border-l-gray-300"
}

function BlockerBanner({ blocker }: { blocker: ChatJobStatusBlocker }) {
  const { t } = useT("chat")
  const label =
    blocker.reason === "awaiting_review" ? t("job_status_blocker_awaiting_review") :
      blocker.reason === "landing_failed" ? t("job_status_blocker_landing_failed") :
        t("job_status_blocker_dependency_failed")

  return (
    <div className="mt-1.5 flex items-center gap-1.5 rounded bg-red-50 px-2 py-1 text-xs text-red-700 dark:bg-red-950/50 dark:text-red-300">
      <svg aria-hidden="true" className="h-3 w-3 shrink-0 text-red-500" fill="currentColor" viewBox="0 0 20 20">
        <path clipRule="evenodd" d="M18 10a8 8 0 1 1-16 0 8 8 0 0 1 16 0zm-7-4a1 1 0 1 1-2 0 1 1 0 0 1 2 0zM9 9a1 1 0 0 0 0 2v3a1 1 0 0 0 1 1h1a1 1 0 1 0 0-2V9a1 1 0 0 0-1-1H9z" fillRule="evenodd" />
      </svg>
      {label}
    </div>
  )
}

function JobStatusCard({ job, onClick }: { job: ChatJobStatusJobItem; onClick: () => void }) {
  const { t } = useT("chat")

  return (
    <button
      className={`w-full cursor-pointer border-l-4 bg-white px-3 py-2.5 text-left transition hover:bg-gray-50 dark:bg-gray-900 dark:hover:bg-gray-800 ${jobBorderClass(job)}`}
      onClick={onClick}
      type="button"
    >
      <div className="flex items-start justify-between gap-2">
        <div className="min-w-0 flex-1">
          <p className="truncate text-sm font-medium text-gray-900 dark:text-gray-100">
            {job.title || job.slug}
          </p>
          <div className="mt-0.5 flex items-center gap-2">
            <span className="font-mono text-xs text-gray-400 dark:text-gray-500">{job.slug}</span>
            {job.workflow_step ? (
              <span className="truncate text-xs text-gray-500 dark:text-gray-400">
                {t("job_status_step", { step: job.workflow_step.replaceAll("_", " ") })}
              </span>
            ) : null}
            {job.pr_number && job.pr_url ? (
              <a
                className="text-xs text-blue-600 hover:underline dark:text-blue-400"
                href={job.pr_url}
                onClick={(e) => e.stopPropagation()}
                rel="noreferrer"
                target="_blank"
              >
                {t("job_status_pr", { number: job.pr_number })}
              </a>
            ) : null}
          </div>
          {job.blocker ? <BlockerBanner blocker={job.blocker} /> : null}
        </div>
        <StatusPill state={job.state} />
      </div>
    </button>
  )
}

function EpicSection({ epic, hideClosedJobs, onJobClick }: { epic: ChatJobStatusEpicItem; hideClosedJobs: boolean; onJobClick: (jobId: number) => void }) {
  const [expanded, setExpanded] = useState(true)
  const { t } = useT("chat")

  const visibleChildren = hideClosedJobs
    ? epic.children.filter((j) => j.state !== "closed")
    : epic.children

  const ariaLabel = expanded
    ? t("job_status_collapse_epic", { title: epic.title || epic.slug })
    : t("job_status_expand_epic", { title: epic.title || epic.slug })

  return (
    <div className="rounded border border-gray-200 dark:border-gray-700">
      <button
        aria-label={ariaLabel}
        className="flex w-full items-center justify-between gap-2 px-3 py-2 text-left hover:bg-gray-50 dark:hover:bg-gray-800"
        onClick={() => setExpanded(!expanded)}
        type="button"
      >
        <div className="flex min-w-0 items-center gap-2">
          <span className="font-mono text-xs font-medium text-gray-500 dark:text-gray-400">{epic.slug}</span>
          <span className="truncate text-sm font-medium text-gray-900 dark:text-gray-100">{epic.title}</span>
        </div>
        <div className="flex shrink-0 items-center gap-2">
          <span className="rounded-full bg-gray-100 px-2 py-0.5 text-xs font-medium text-gray-600 dark:bg-gray-800 dark:text-gray-300">
            {t("job_status_epic_progress", { done: epic.progress.done, total: epic.progress.total })}
          </span>
          <svg
            aria-hidden="true"
            className={`h-4 w-4 shrink-0 text-gray-400 transition-transform ${expanded ? "rotate-180" : ""}`}
            fill="none"
            stroke="currentColor"
            strokeLinecap="round"
            strokeLinejoin="round"
            strokeWidth="2"
            viewBox="0 0 24 24"
          >
            <polyline points="6 9 12 15 18 9" />
          </svg>
        </div>
      </button>
      {expanded && visibleChildren.length > 0 ? (
        <div className="divide-y divide-gray-100 border-t border-gray-100 dark:divide-gray-800 dark:border-gray-800">
          {visibleChildren.map((job) => (
            <JobStatusCard key={job.job_id} job={job} onClick={() => onJobClick(job.job_id)} />
          ))}
        </div>
      ) : null}
    </div>
  )
}

export function ChatJobStatusPanel({ chatId }: { chatId: string | number }) {
  const queryClient = useQueryClient()
  const { t } = useT("chat")
  const navigate = useNavigate()
  const [hideClosedJobs, setHideClosedJobs] = useState(false)

  const { data, isLoading, isError } = useQuery({
    queryKey: ["chats", String(chatId), "job_status"],
    queryFn: () => fetchChatJobStatus(chatId),
    staleTime: 30_000
  })

  useEffect(() => {
    function handleStatusChanged(event: Event) {
      const detail = (event as CustomEvent<{ chat_session_id: unknown }>).detail
      if (String(detail?.chat_session_id) === String(chatId)) {
        void queryClient.invalidateQueries({ queryKey: ["chats", String(chatId), "job_status"] })
      }
    }
    window.addEventListener("syrus:job-status-changed", handleStatusChanged)
    return () => window.removeEventListener("syrus:job-status-changed", handleStatusChanged)
  }, [chatId, queryClient])

  if (isLoading) {
    return <p className="text-sm text-gray-500 dark:text-gray-400">{t("job_status_loading")}</p>
  }

  if (isError) {
    return <p className="text-sm text-red-600 dark:text-red-400">{t("job_status_error")}</p>
  }

  const items: ChatJobStatusItem[] = Array.isArray(data) ? data : []

  if (items.length === 0) {
    return <p className="text-sm text-gray-500 dark:text-gray-400">{t("job_status_empty")}</p>
  }

  const epics = items.filter((item): item is ChatJobStatusEpicItem => item.kind === "epic")
  const jobs = items.filter((item): item is ChatJobStatusJobItem => item.kind === "job")

  const visibleEpics = hideClosedJobs
    ? epics.filter((epic) => epic.children.some((j) => j.state !== "closed"))
    : epics

  const visibleJobs = hideClosedJobs
    ? jobs.filter((j) => j.state !== "closed")
    : jobs

  const hasClosedItems =
    jobs.some((j) => j.state === "closed") ||
    epics.some((epic) => epic.children.some((j) => j.state === "closed"))

  function navigateToJob(jobId: number) {
    navigate(`/jobs/${jobId}`)
  }

  return (
    <div className="space-y-3">
      {hasClosedItems ? (
        <div className="flex justify-end">
          <button
            className="text-xs text-gray-500 hover:text-gray-700 dark:text-gray-400 dark:hover:text-gray-200"
            onClick={() => setHideClosedJobs((h) => !h)}
            type="button"
          >
            {hideClosedJobs ? t("job_status_show_closed") : t("job_status_hide_closed")}
          </button>
        </div>
      ) : null}
      {visibleEpics.map((epic) => (
        <EpicSection epic={epic} hideClosedJobs={hideClosedJobs} key={epic.epic_id} onJobClick={navigateToJob} />
      ))}
      {visibleJobs.length > 0 ? (
        <div className="divide-y divide-gray-100 rounded border border-gray-200 dark:divide-gray-800 dark:border-gray-700">
          {visibleJobs.map((job) => (
            <JobStatusCard job={job} key={job.job_id} onClick={() => navigateToJob(job.job_id)} />
          ))}
        </div>
      ) : null}
    </div>
  )
}
