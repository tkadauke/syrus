import { useQuery, useQueryClient } from "@tanstack/react-query"
import { useEffect, useState, type KeyboardEvent } from "react"
import { useNavigate } from "react-router-dom"
import type { ChatJobStatusBlocker, ChatJobStatusEpicItem, ChatJobStatusItem, ChatJobStatusJobItem, ChatJobStatusPendingProposal } from "../api/chats"
import { fetchChatJobStatus } from "../api/chats"
import { useT } from "../hooks/useT"
import { CopyableSlug } from "../components/CopyableSlug"
import { RelativeTimestamp } from "../components/RelativeTimestamp"
import { SlugHoverCard } from "../components/SlugHoverCard"
import { StatusPill } from "../components/StatusPill"

function jobBorderClass(job: ChatJobStatusJobItem): string {
  if (job.blocker) return job.blocker.reason === "awaiting_review" ? "border-l-amber-400" : "border-l-red-500"

  const s = job.active_workflow?.state || job.state
  if (s === "pr_merged" || s === "external_pr_merged" || s === "no_changes") return "border-l-emerald-500"
  if (s === "implemented" || s === "approved" || s === "landing") return "border-l-amber-400"
  if (s === "open" || s === "coding" || s === "queued" || s === "running") return "border-l-info"
  return "border-l-gray-300"
}

function BlockerBanner({ blocker }: { blocker: ChatJobStatusBlocker }) {
  const { t } = useT("chat")
  const isAwaitingReview = blocker.reason === "awaiting_review"
  const label =
    isAwaitingReview ? t("job_status_blocker_awaiting_review") :
      blocker.reason === "landing_failed" ? t("job_status_blocker_landing_failed") :
        t("job_status_blocker_dependency_failed")

  // Awaiting review is an expected, natural step, not a failure. This
  // intentionally uses the literal Tailwind amber palette rather than the
  // semantic "warning" token: in the built-in Terracotta theme,
  // --color-warning is set to the brand accent color, a muted red-orange
  // that reads as red right next to the "danger" tone used below. A fixed
  // amber avoids that per-theme collision and matches the amber left-border
  // accent already used for other in-progress-but-not-failed job states.
  const toneClasses = isAwaitingReview
    ? "bg-amber-50 text-amber-800 dark:bg-amber-950/40 dark:text-amber-200"
    : "bg-red-50 text-red-700 dark:bg-red-950/50 dark:text-red-300"
  const iconClasses = isAwaitingReview ? "text-amber-500" : "text-red-500"

  return (
    <div className={`mt-1.5 flex items-center gap-1.5 rounded px-2 py-1 text-xs ${toneClasses}`}>
      <svg aria-hidden="true" className={`h-3 w-3 shrink-0 ${iconClasses}`} fill="currentColor" viewBox="0 0 20 20">
        <path clipRule="evenodd" d="M18 10a8 8 0 1 1-16 0 8 8 0 0 1 16 0zm-7-4a1 1 0 1 1-2 0 1 1 0 0 1 2 0zM9 9a1 1 0 0 0 0 2v3a1 1 0 0 0 1 1h1a1 1 0 1 0 0-2V9a1 1 0 0 0-1-1H9z" fillRule="evenodd" />
      </svg>
      {label}
    </div>
  )
}

function activateOnEnterOrSpace(event: KeyboardEvent<HTMLDivElement>, callback: () => void) {
  if (event.target !== event.currentTarget) return

  if (event.key === "Enter" || event.key === " ") {
    event.preventDefault()
    callback()
  }
}

function JobStatusCard({ job, onClick }: { job: ChatJobStatusJobItem; onClick: () => void }) {
  const { t } = useT("chat")
  const workflowStep = job.active_workflow?.step || job.workflow_step

  return (
    <div
      className={`w-full cursor-pointer border-l-4 bg-white px-3 py-2.5 text-left transition hover:bg-gray-50 dark:bg-gray-900 dark:hover:bg-gray-800 ${jobBorderClass(job)}`}
      onClick={onClick}
      onKeyDown={(event) => activateOnEnterOrSpace(event, onClick)}
      role="button"
      tabIndex={0}
    >
      <div className="flex items-start justify-between gap-2">
        <div className="min-w-0 flex-1">
          <p className="truncate text-sm font-medium text-gray-900 dark:text-gray-100">
            {job.title || job.slug}
          </p>
          <div className="mt-0.5 flex items-center gap-2">
            <span onClick={(e) => e.stopPropagation()}>
              <SlugHoverCard kind="job" id={job.job_id}>
                <CopyableSlug slug={job.slug} className="text-xs" />
              </SlugHoverCard>
            </span>
            {workflowStep ? (
              <span className="truncate text-xs text-gray-500 dark:text-gray-400">
                {t("job_status_step", { step: workflowStep.replaceAll("_", " ") })}
              </span>
            ) : null}
            {job.pr_number && job.pr_url ? (
              <a
                className="text-xs text-brand hover:underline dark:text-brand-emphasis"
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
        <StatusPill state={job.active_workflow?.state || job.state} />
      </div>
    </div>
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
      <div
        aria-label={ariaLabel}
        className="flex w-full items-center justify-between gap-2 px-3 py-2 text-left hover:bg-gray-50 dark:hover:bg-gray-800"
        onClick={() => setExpanded(!expanded)}
        onKeyDown={(event) => activateOnEnterOrSpace(event, () => setExpanded((value) => !value))}
        role="button"
        tabIndex={0}
      >
        <div className="flex min-w-0 items-center gap-2">
          <span className="shrink-0" onClick={(e) => e.stopPropagation()}>
            <SlugHoverCard kind="epic" id={epic.epic_id}>
              <CopyableSlug slug={epic.slug} className="text-xs font-medium" />
            </SlugHoverCard>
          </span>
          <span className="min-w-0 truncate text-sm font-medium text-gray-900 dark:text-gray-100">{epic.title}</span>
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
      </div>
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

function proposalKindLabel(proposal: ChatJobStatusPendingProposal, t: (key: string) => string): string {
  if (proposal.kind === "epic") return t("job_status_proposal_kind_epic")
  if (proposal.kind === "syrus_issue") return t("job_status_proposal_kind_syrus_issue")

  return t("job_status_proposal_kind_job")
}

function ProposedProposalsSection({ proposals, onSelectMessage }: { proposals: ChatJobStatusPendingProposal[]; onSelectMessage?: (messageId: number) => void }) {
  const { t } = useT("chat")

  if (proposals.length === 0) return null

  return (
    <div aria-label={t("job_status_proposed_title")} className="space-y-1.5">
      <p className="text-xs font-medium uppercase tracking-wide text-text-muted">
        {t("job_status_proposed_title")}
      </p>
      <div className="divide-y divide-border rounded border border-border">
        {proposals.map((proposal) => {
          const clickable = Boolean(onSelectMessage && proposal.anchor_message_id)
          const handleClick = clickable ? () => onSelectMessage?.(proposal.anchor_message_id as number) : undefined

          return (
            <div
              className={`w-full bg-surface px-3 py-2.5 text-left ${clickable ? "cursor-pointer transition hover:bg-surface-raised" : ""}`}
              key={`${proposal.kind}-${proposal.id}`}
              onClick={handleClick}
              onKeyDown={clickable ? (event) => activateOnEnterOrSpace(event, () => handleClick?.()) : undefined}
              role={clickable ? "button" : undefined}
              tabIndex={clickable ? 0 : undefined}
            >
              <div className="flex items-start justify-between gap-2">
                <p className="min-w-0 flex-1 truncate text-sm font-medium text-text-primary">
                  {proposal.title}
                </p>
                <RelativeTimestamp className="shrink-0 text-xs text-text-muted" value={proposal.created_at} />
              </div>
              <div className="mt-0.5 flex items-center gap-2 text-xs text-text-muted">
                <span className="rounded-full bg-surface-subtle px-2 py-0.5 font-medium text-text-secondary">
                  {proposalKindLabel(proposal, t)}
                </span>
                {proposal.kind === "epic" && proposal.active_children_count != null ? (
                  <span>{t("job_status_proposal_child_count", { count: proposal.active_children_count })}</span>
                ) : null}
              </div>
            </div>
          )
        })}
      </div>
    </div>
  )
}

export function ChatJobStatusPanel({ chatId, onSelectMessage }: { chatId: string | number; onSelectMessage?: (messageId: number) => void }) {
  const queryClient = useQueryClient()
  const { t } = useT("chat")
  const navigate = useNavigate()
  const [hideClosedJobs, setHideClosedJobs] = useState(
    () => localStorage.getItem("chat_jobs_hide_closed") === "true"
  )

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

  const pendingProposals = data?.pending_proposals ?? []
  const items: ChatJobStatusItem[] = data?.items ?? []

  if (items.length === 0 && pendingProposals.length === 0) {
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
      <ProposedProposalsSection onSelectMessage={onSelectMessage} proposals={pendingProposals} />
      {hasClosedItems ? (
        <div className="flex justify-end">
          <button
            className="text-xs text-gray-500 hover:text-gray-700 dark:text-gray-400 dark:hover:text-gray-200"
            onClick={() => setHideClosedJobs((h) => {
              const next = !h
              localStorage.setItem("chat_jobs_hide_closed", String(next))
              return next
            })}
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
