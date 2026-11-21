import { fetchJobDetail, fetchJobTab, postJobCommand, submitJobFeedback, type JobDetailPayload } from "@app/api/jobs"
import { Button } from "@app/components/Button"
import { CloseIcon } from "@app/components/CloseIcon"
import { Notice } from "@app/components/ui"
import { usePageTitle } from "@app/hooks/usePageTitle"
import { useT } from "@app/hooks/useT"
import { errorMessage } from "@app/lib/errorMessage"
import { normalizeJobDetailPayload } from "@app/lib/entityStore"
import { routePrefix, withRoutePrefix } from "@app/lib/routing"
import { ReviewWorkspace as CanonicalReviewWorkspace } from "@app/routes/jobDetail/ReviewWorkspace"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { type ReactNode, useCallback, useEffect, useRef, useState } from "react"
import { Link, Navigate, useLocation, useNavigate, useParams } from "react-router-dom"
import { fetchReviewWorkspace, type ReviewWorkspaceJob } from "../api/reviewWorkspace"

const WORKSPACE_SCROLL_CLASS =
  "h-[calc(100dvh-4rem)] shrink-0 overflow-x-hidden overflow-y-scroll overscroll-contain [-webkit-overflow-scrolling:touch] lg:grid lg:h-auto lg:min-h-0 lg:flex-1 lg:grid-cols-[17rem_minmax(0,1fr)_20rem] lg:overflow-hidden"

export default function ReviewWorkspaceRoute() {
  const { t } = useT("review_workspace")
  const location = useLocation()
  const navigate = useNavigate()
  const { job_id: requestedJobId } = useParams()
  const prefix = routePrefix(location.pathname)
  const review = useQuery({ queryKey: ["review_workspace"], queryFn: fetchReviewWorkspace })
  const [deferred, setDeferred] = useState<Set<number>>(() => new Set())
  const [loadedDetail, setLoadedDetail] = useState<{ jobId: number; payload: JobDetailPayload } | null>(null)
  const [evidenceNavigation, setEvidenceNavigation] = useState<{ direction: -1 | 1; sequence: number }>()
  const [conversationTarget, setConversationTarget] = useState<HTMLDivElement | null>(null)
  const exitRef = useRef<HTMLButtonElement>(null)
  const handleDetail = useCallback((jobId: number, payload: JobDetailPayload) => setLoadedDetail({ jobId, payload }), [])
  usePageTitle(t("title"))
  useEffect(() => exitRef.current?.focus(), [review.isSuccess])

  function exitWorkspace() {
    if (window.history.length > 1) navigate(-1)
    else navigate(withRoutePrefix("/", prefix))
    window.setTimeout(() => document.querySelector<HTMLElement>('a[href*="/review"]')?.focus(), 0)
  }

  if (review.isPending)
    return (
      <WorkspaceMessage>
        <Notice>{t("common:loading")}</Notice>
      </WorkspaceMessage>
    )
  if (review.isError && !review.data)
    return (
      <WorkspaceMessage>
        <Notice tone="danger">{t("load_error")}</Notice>
      </WorkspaceMessage>
    )

  const jobs = (review.data?.jobs ?? []).filter((job) => !deferred.has(job.id))
  if (jobs.length === 0) return <EmptyWorkspace onExit={exitWorkspace} />
  const active = jobs.find((job) => job.slug === requestedJobId || String(job.id) === requestedJobId) ?? jobs[0]
  const canonicalPath = withRoutePrefix(`/review/${active.slug}`, prefix)
  if (location.pathname !== canonicalPath) return <Navigate replace to={canonicalPath} />

  return (
    <main aria-label={t("title")} className="fixed inset-0 z-50 flex h-dvh min-h-0 flex-col overflow-hidden bg-page text-text">
      <header className="flex h-16 shrink-0 items-center justify-between border-b border-border bg-surface px-4">
        <div className="flex min-w-0 items-center gap-3">
          <strong>{t("title")}</strong>
          <span className="text-sm text-text-secondary">{t("position", { current: jobs.indexOf(active) + 1, count: jobs.length })}</span>
        </div>
        <button
          aria-label={t("exit")}
          className="rounded border border-border bg-surface p-2 hover:bg-surface-subtle focus-visible:outline-brand"
          onClick={exitWorkspace}
          ref={exitRef}
          type="button"
        >
          <CloseIcon className="h-5 w-5" />
        </button>
      </header>
      <div className={WORKSPACE_SCROLL_CLASS} data-testid="review-workspace-scroll-container">
        <JobRail active={active} jobs={jobs} prefix={prefix} />
        <JobReview conversationTarget={conversationTarget} job={active} onDetail={handleDetail} visualEvidenceNavigation={evidenceNavigation} />
        <DecisionPanel
          detail={loadedDetail?.jobId === active.id ? loadedDetail.payload : undefined}
          job={active}
          onCompleted={() => {
            setDeferred((current) => new Set(current).add(active.id))
            void review.refetch()
          }}
          onDefer={() => setDeferred((current) => new Set(current).add(active.id))}
          onEvidenceMove={(direction) => setEvidenceNavigation((current) => ({ direction, sequence: (current?.sequence ?? 0) + 1 }))}
          onExit={exitWorkspace}
          onMove={(offset) => navigate(withRoutePrefix(`/review/${jobs[(jobs.indexOf(active) + offset + jobs.length) % jobs.length].slug}`, prefix))}
          setConversationTarget={setConversationTarget}
        />
      </div>
    </main>
  )
}

function JobRail({ active, jobs, prefix }: { active: ReviewWorkspaceJob; jobs: ReviewWorkspaceJob[]; prefix: string }) {
  const { t } = useT("review_workspace")
  return (
    <aside aria-label={t("ready_now")} className="hidden overflow-y-auto border-r border-border bg-surface p-3 lg:block">
      <h2 className="px-2 pb-2 text-xs font-semibold uppercase tracking-wider text-text-secondary">{t("ready_now")}</h2>
      <div className="space-y-1">
        {jobs.map((job) => (
          <Link
            aria-current={job.id === active.id ? "page" : undefined}
            className={`block rounded-lg border p-3 ${job.id === active.id ? "border-brand bg-brand-subtle" : "border-transparent hover:bg-surface-subtle"}`}
            key={job.id}
            to={withRoutePrefix(`/review/${job.slug}`, prefix)}
          >
            <div className="flex justify-between gap-2 text-xs text-text-secondary">
              <span>{job.slug}</span>
              <span>{t("ready")}</span>
            </div>
            <div className="mt-1 text-sm font-medium leading-snug">{job.title}</div>
          </Link>
        ))}
      </div>
    </aside>
  )
}

function JobReview({
  conversationTarget,
  job,
  onDetail,
  visualEvidenceNavigation
}: {
  conversationTarget: HTMLDivElement | null
  job: ReviewWorkspaceJob
  onDetail: (jobId: number, payload: JobDetailPayload) => void
  visualEvidenceNavigation?: { direction: -1 | 1; sequence: number }
}) {
  const { t } = useT("review_workspace")
  const detail = useQuery({
    queryKey: ["review_workspace", "job", job.id],
    queryFn: async () => {
      const [header, summary, review] = await Promise.all([
        fetchJobDetail(String(job.id)),
        fetchJobTab(String(job.id), "summary"),
        fetchJobTab(String(job.id), "review")
      ])
      return normalizeJobDetailPayload(
        {
          ...header,
          attachments: [],
          typed_artifacts: [],
          coverage: null,
          summary: null,
          test_plan: null,
          report: null,
          feedback_history: [],
          ...summary,
          ...review
        } as JobDetailPayload,
        "focused_review_workspace"
      )
    }
  })
  useEffect(() => {
    if (detail.data) onDetail(job.id, detail.data)
  }, [detail.data, job.id, onDetail])
  if (detail.isPending)
    return (
      <section className="overflow-y-auto p-5">
        <Notice>{t("loading_job")}</Notice>
      </section>
    )
  if (detail.isError)
    return (
      <section className="overflow-y-auto p-5">
        <Notice tone="danger">{t("job_load_error")}</Notice>
      </section>
    )
  return (
    <section aria-label={t("evidence")} className="min-w-0 bg-page p-4 sm:p-6 lg:overflow-y-auto">
      <div className="mb-5">
        <p className="text-xs text-text-secondary">
          {job.slug} · {job.repository.slug}
        </p>
        <h1 className="mt-1 text-2xl font-semibold tracking-tight">{job.title}</h1>
      </div>
      <CanonicalReviewWorkspace
        conversationPortalTarget={conversationTarget}
        payload={detail.data}
        showConversation={false}
        showEmptyVisualEvidence
        visualEvidenceNavigation={visualEvidenceNavigation}
      />
    </section>
  )
}

function DecisionPanel({
  detail,
  job,
  onCompleted,
  onDefer,
  onEvidenceMove,
  onExit,
  onMove,
  setConversationTarget
}: {
  detail?: JobDetailPayload
  job: ReviewWorkspaceJob
  onCompleted: () => void
  onDefer: () => void
  onEvidenceMove: (direction: -1 | 1) => void
  onExit: () => void
  onMove: (offset: number) => void
  setConversationTarget: (target: HTMLDivElement | null) => void
}) {
  const { t } = useT("review_workspace")
  const queryClient = useQueryClient()
  const [feedbackOpen, setFeedbackOpen] = useState(false)
  const [feedback, setFeedback] = useState("")
  const [confirming, setConfirming] = useState(false)
  async function completed() {
    await queryClient.invalidateQueries({ queryKey: ["review_workspace"] })
    await queryClient.invalidateQueries({ queryKey: ["jobs", String(job.id)] })
    onCompleted()
  }
  const canApprove = Boolean(detail?.actions.can_approve && detail.job.summary_state.toLowerCase() === "implemented" && detail.paths.app_approve_path)
  const approve = useMutation({ mutationFn: () => postJobCommand(detail!.paths.app_approve_path), onSuccess: completed })
  const submitFeedback = useMutation({ mutationFn: () => submitJobFeedback(job.id, feedback.trim()), onSuccess: completed })
  useEffect(() => {
    const shortcut = (event: KeyboardEvent) => {
      if (event.target instanceof HTMLInputElement || event.target instanceof HTMLTextAreaElement) return
      const key = event.key.toLowerCase()
      if (key === "a" && canApprove) setConfirming(true)
      if (key === "f") setFeedbackOpen(true)
      if (key === "j") onMove(1)
      if (key === "k") onMove(-1)
      if (event.key === "ArrowLeft") onEvidenceMove(-1)
      if (event.key === "ArrowRight") onEvidenceMove(1)
      if (event.key === "Escape") onExit()
    }
    window.addEventListener("keydown", shortcut)
    return () => window.removeEventListener("keydown", shortcut)
  }, [canApprove, onEvidenceMove, onExit, onMove])
  const mutationError = approve.error ?? submitFeedback.error
  return (
    <aside aria-label={t("decision_context")} className="border-l border-border bg-surface p-5 max-lg:border-t lg:overflow-y-auto">
      <h2 className="font-semibold">{t("decision_context")}</h2>
      <p className="mt-2 text-sm text-text-secondary">{t("decision_hint")}</p>
      <section className="mt-5 border-t border-border pt-4" aria-label={t("checks")}>
        <h3 className="text-xs font-semibold uppercase tracking-wider text-text-secondary">{t("checks")}</h3>
        <p className={`mt-2 text-sm ${canApprove ? "text-success-text" : "text-text-secondary"}`}>{canApprove ? t("checks_ready") : t("checks_blocked")}</p>
      </section>
      <section className="mt-4 border-t border-border pt-4" aria-label={t("findings")}>
        <h3 className="text-xs font-semibold uppercase tracking-wider text-text-secondary">{t("findings")}</h3>
        <div className="mt-2" ref={setConversationTarget} />
      </section>
      <div className="mt-5 space-y-2">
        {confirming ? (
          <div className="rounded border border-brand/30 bg-brand-subtle p-3">
            <p className="text-sm font-medium">{t("approve_confirm", { slug: job.slug })}</p>
            <div className="mt-3 flex gap-2">
              <Button disabled={approve.isPending} onClick={() => setConfirming(false)} variant="secondary">
                {t("common:cancel")}
              </Button>
              <Button disabled={approve.isPending} onClick={() => approve.mutate()} variant="primary">
                {t("approve")}
              </Button>
            </div>
          </div>
        ) : (
          <Button className="w-full" disabled={!canApprove} onClick={() => setConfirming(true)} variant="primary">
            {t("approve_shortcut")}
          </Button>
        )}
        <Button className="w-full" onClick={() => setFeedbackOpen(true)} variant="secondary">
          {t("feedback_shortcut")}
        </Button>
        <Button className="w-full" onClick={onDefer} variant="secondary">
          {t("defer")}
        </Button>
      </div>
      {feedbackOpen ? (
        <form
          className="mt-4 space-y-2"
          onSubmit={(event) => {
            event.preventDefault()
            if (feedback.trim()) submitFeedback.mutate()
          }}
        >
          <label className="block text-sm font-medium" htmlFor="focused-review-feedback">
            {t("feedback_label")}
          </label>
          <textarea
            autoFocus
            className="min-h-28 w-full rounded border border-border bg-page p-2 text-sm"
            id="focused-review-feedback"
            onChange={(event) => setFeedback(event.target.value)}
            value={feedback}
          />
          <div className="flex gap-2">
            <Button onClick={() => setFeedbackOpen(false)} variant="secondary">
              {t("common:cancel")}
            </Button>
            <Button disabled={!feedback.trim() || submitFeedback.isPending} type="submit" variant="primary">
              {t("send_feedback")}
            </Button>
          </div>
        </form>
      ) : null}
      {mutationError ? (
        <p className="mt-3 text-sm text-danger-text" role="alert">
          {errorMessage(mutationError, t("mutation_error"))}
        </p>
      ) : null}
      <p className="mt-5 text-xs text-text-secondary">{t("shortcuts")}</p>
    </aside>
  )
}

function WorkspaceMessage({ children }: { children: ReactNode }) {
  return <main className="fixed inset-0 z-50 grid place-items-center bg-page p-6">{children}</main>
}
function EmptyWorkspace({ onExit }: { onExit: () => void }) {
  const { t } = useT("review_workspace")
  return (
    <WorkspaceMessage>
      <div className="text-center">
        <h1 className="text-2xl font-semibold">{t("all_caught_up")}</h1>
        <p className="mt-2 text-text-secondary">{t("empty")}</p>
        <Button className="mt-5" onClick={onExit} variant="secondary">
          {t("exit")}
        </Button>
      </div>
    </WorkspaceMessage>
  )
}
