import { fetchJobDetail, fetchJobTab, postJobCommand, submitJobFeedback, type JobDetailPayload } from "@app/api/jobs"
import { Button } from "@app/components/Button"
import { CloseIcon } from "@app/components/CloseIcon"
import { Notice } from "@app/components/ui"
import { usePageTitle } from "@app/hooks/usePageTitle"
import { useT } from "@app/hooks/useT"
import { errorMessage } from "@app/lib/errorMessage"
import { addAppEventListener } from "@app/lib/appEvents"
import { normalizeJobDetailPayload } from "@app/lib/entityStore"
import { Markdown } from "@app/lib/Markdown"
import { routePrefix, withRoutePrefix } from "@app/lib/routing"
import { ReviewWorkspace as CanonicalReviewWorkspace } from "@app/routes/jobDetail/ReviewWorkspace"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { type PointerEvent as ReactPointerEvent, type ReactNode, useCallback, useEffect, useRef, useState } from "react"
import { Link, Navigate, useLocation, useNavigate, useParams } from "react-router-dom"
import { fetchReviewWorkspace, type ReviewWorkspaceJob } from "../api/reviewWorkspace"

const WORKSPACE_SCROLL_CLASS =
  "h-[calc(100dvh-4rem)] shrink-0 overflow-x-hidden overflow-y-scroll overscroll-contain [-webkit-overflow-scrolling:touch] lg:grid lg:h-auto lg:min-h-0 lg:flex-1 lg:grid-cols-[17rem_minmax(0,1fr)_20rem] lg:overflow-hidden"
const MOBILE_ACTION_BAR_CLASS =
  "mt-5 space-y-2 max-lg:fixed max-lg:inset-x-3 max-lg:bottom-[max(.75rem,env(safe-area-inset-bottom))] max-lg:z-20 max-lg:grid max-lg:grid-cols-4 max-lg:gap-2 max-lg:space-y-0 max-lg:rounded-xl max-lg:border max-lg:border-border max-lg:bg-surface/95 max-lg:p-2 max-lg:shadow-lg max-lg:backdrop-blur"
const MOBILE_FEEDBACK_SHEET_CLASS =
  "mt-4 space-y-2 max-lg:fixed max-lg:inset-x-0 max-lg:bottom-0 max-lg:z-30 max-lg:rounded-t-2xl max-lg:border max-lg:border-border max-lg:bg-surface max-lg:p-5 max-lg:pb-[max(1.25rem,env(safe-area-inset-bottom))] max-lg:shadow-xl"

export default function ReviewWorkspaceRoute() {
  const { t } = useT("review_workspace")
  const location = useLocation()
  const navigate = useNavigate()
  const { job_id: requestedJobId } = useParams()
  const prefix = routePrefix(location.pathname)
  const isDesktop = useDesktopReviewLayout()
  const review = useQuery({ queryKey: ["review_workspace"], queryFn: fetchReviewWorkspace, refetchInterval: 30_000 })
  const queryClient = useQueryClient()
  const [deferred, setDeferred] = useState<Set<number>>(() => new Set())
  const [loadedDetail, setLoadedDetail] = useState<{ jobId: number; payload: JobDetailPayload } | null>(null)
  const [evidenceNavigation, setEvidenceNavigation] = useState<{ jobId: number; direction: -1 | 1; sequence: number }>()
  const [gestureIntent, setGestureIntent] = useState<{ jobId: number; sequence: number }>()
  const [detailsJobId, setDetailsJobId] = useState<number | null>(null)
  const [conversationTarget, setConversationTarget] = useState<HTMLDivElement | null>(null)
  const exitRef = useRef<HTMLButtonElement>(null)
  const handleDetail = useCallback((jobId: number, payload: JobDetailPayload) => setLoadedDetail({ jobId, payload }), [])
  usePageTitle(t("title"))
  useEffect(() => exitRef.current?.focus(), [review.isSuccess])
  useEffect(
    () =>
      addAppEventListener((event) => {
        if (event.resource !== "job" && event.resource !== "workflow") return
        void queryClient.invalidateQueries({ queryKey: ["review_workspace"] })
      }),
    [queryClient]
  )

  function exitWorkspace() {
    if (window.history.length > 1) navigate(-1)
    else navigate(withRoutePrefix("/", prefix))
    window.setTimeout(() => {
      const reviewLink = document.querySelector('a[href*="/review"]') as HTMLElement | null
      reviewLink?.focus()
    }, 0)
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
        <div className="flex items-center gap-1">
          {jobs.length > 1 ? (
            <>
              <button
                aria-label={t("previous_job")}
                className="min-h-11 min-w-11 rounded border border-border bg-surface px-2 text-sm lg:hidden"
                onClick={() => navigate(withRoutePrefix(`/review/${jobs[(jobs.indexOf(active) - 1 + jobs.length) % jobs.length].slug}`, prefix))}
                type="button"
              >
                ↑
              </button>
              <button
                aria-label={t("next_job")}
                className="min-h-11 min-w-11 rounded border border-border bg-surface px-2 text-sm lg:hidden"
                onClick={() => navigate(withRoutePrefix(`/review/${jobs[(jobs.indexOf(active) + 1) % jobs.length].slug}`, prefix))}
                type="button"
              >
                ↓
              </button>
            </>
          ) : null}
          <button
            aria-label={t("details")}
            className="min-h-11 min-w-11 rounded border border-border bg-surface px-2 text-sm lg:hidden"
            onClick={() => setDetailsJobId(active.id)}
            type="button"
          >
            …
          </button>
          <button
            aria-label={t("exit")}
            className="min-h-11 min-w-11 rounded border border-border bg-surface p-2 hover:bg-surface-subtle focus-visible:outline-brand"
            onClick={exitWorkspace}
            ref={exitRef}
            type="button"
          >
            <CloseIcon className="h-5 w-5" />
          </button>
        </div>
      </header>
      <div className={WORKSPACE_SCROLL_CLASS} data-review-workspace-scroll-container data-testid="review-workspace-scroll-container">
        <JobRail active={active} jobs={jobs} prefix={prefix} />
        <MobileGestureSurface
          onApprove={() => setGestureIntent((current) => ({ jobId: active.id, sequence: (current?.sequence ?? 0) + 1 }))}
          onDefer={() => setDeferred((current) => new Set(current).add(active.id))}
          onDetails={() => setDetailsJobId(active.id)}
          onMove={(offset) => navigate(withRoutePrefix(`/review/${jobs[(jobs.indexOf(active) + offset + jobs.length) % jobs.length].slug}`, prefix))}
        >
          <JobReview
            conversationTarget={conversationTarget}
            isDesktop={isDesktop}
            job={active}
            onDetail={handleDetail}
            onDetails={() => setDetailsJobId(active.id)}
            visualEvidenceNavigation={evidenceNavigation?.jobId === active.id ? evidenceNavigation : undefined}
          />
        </MobileGestureSurface>
        <DecisionPanel
          detail={loadedDetail?.jobId === active.id ? loadedDetail.payload : undefined}
          job={active}
          onCompleted={() => {
            setDeferred((current) => new Set(current).add(active.id))
            void review.refetch()
          }}
          onDefer={() => setDeferred((current) => new Set(current).add(active.id))}
          onEvidenceMove={(direction) => setEvidenceNavigation((current) => ({ jobId: active.id, direction, sequence: (current?.sequence ?? 0) + 1 }))}
          onExit={exitWorkspace}
          onMove={(offset) => navigate(withRoutePrefix(`/review/${jobs[(jobs.indexOf(active) + offset + jobs.length) % jobs.length].slug}`, prefix))}
          setConversationTarget={setConversationTarget}
          gestureIntent={gestureIntent}
          isDesktop={isDesktop}
        />
      </div>
      {detailsJobId === active.id && loadedDetail?.jobId === active.id ? (
        <DetailsSheet job={active} payload={loadedDetail.payload} onClose={() => setDetailsJobId(null)} />
      ) : null}
      <p aria-live="polite" className="sr-only">
        {t("position", { current: jobs.indexOf(active) + 1, count: jobs.length })}
      </p>
    </main>
  )
}

function useDesktopReviewLayout() {
  const [isDesktop, setIsDesktop] = useState(() => window.innerWidth >= 1024)
  useEffect(() => {
    const media = window.matchMedia?.("(min-width: 1024px)")
    if (!media) return
    const update = () => setIsDesktop(media.matches)
    update()
    media.addEventListener?.("change", update)
    return () => media.removeEventListener?.("change", update)
  }, [])
  return isDesktop
}

const SWIPE_THRESHOLD = 72
const DIRECTION_SLOP = 12
const LONG_PRESS_MS = 550

function MobileGestureSurface({
  children,
  onApprove,
  onDefer,
  onDetails,
  onMove
}: {
  children: ReactNode
  onApprove: () => void
  onDefer: () => void
  onDetails: () => void
  onMove: (offset: number) => void
}) {
  const { t } = useT("review_workspace")
  const start = useRef<{
    x: number
    y: number
    lastY: number
    pointerId: number
    pointerType: string
    edge: boolean
    mode?: "gesture" | "scroll"
    scroller: HTMLElement | null
  }>()
  const longPress = useRef<number>()
  const [offset, setOffset] = useState({ x: 0, y: 0 })
  const clearLongPress = () => {
    if (longPress.current) window.clearTimeout(longPress.current)
    longPress.current = undefined
  }
  const reset = () => {
    clearLongPress()
    start.current = undefined
    setOffset({ x: 0, y: 0 })
  }
  function pointerDown(event: ReactPointerEvent<HTMLDivElement>) {
    if (window.innerWidth >= 1024) return
    if (event.pointerType === "mouse" && event.button !== 0) return
    if ((event.target as HTMLElement).closest("button, a, input, textarea, [role='button'], [data-review-gesture-exempt]")) return
    const edge = event.clientX < 28 || event.clientX > window.innerWidth - 28
    start.current = {
      x: event.clientX,
      y: event.clientY,
      lastY: event.clientY,
      pointerId: event.pointerId,
      pointerType: event.pointerType,
      edge,
      scroller: event.currentTarget.closest<HTMLElement>("[data-review-workspace-scroll-container]")
    }
    event.currentTarget.setPointerCapture?.(event.pointerId)
    longPress.current = window.setTimeout(() => {
      if (!start.current) return
      reset()
      onDetails()
    }, LONG_PRESS_MS)
  }
  function pointerMove(event: ReactPointerEvent<HTMLDivElement>) {
    const origin = start.current
    if (!origin || origin.pointerId !== event.pointerId) return
    const x = event.clientX - origin.x
    const y = event.clientY - origin.y
    if (Math.abs(x) > DIRECTION_SLOP || Math.abs(y) > DIRECTION_SLOP) clearLongPress()
    if (origin.edge && x > 0) return
    if (!origin.mode && (Math.abs(x) > DIRECTION_SLOP || Math.abs(y) > DIRECTION_SLOP)) {
      if (origin.pointerType !== "touch" || Math.abs(x) > Math.abs(y)) origin.mode = "gesture"
      else {
        const scroller = origin.scroller
        const atTop = !scroller || scroller.scrollTop <= 0
        const atBottom = !scroller || scroller.scrollTop + scroller.clientHeight >= scroller.scrollHeight - 1
        origin.mode = (y > 0 && atTop) || (y < 0 && atBottom) ? "gesture" : "scroll"
      }
    }
    if (origin.mode === "scroll" && origin.scroller) {
      origin.scroller.scrollTop += origin.lastY - event.clientY
      origin.lastY = event.clientY
      return
    }
    if (!window.matchMedia?.("(prefers-reduced-motion: reduce)").matches)
      setOffset({ x: Math.abs(x) > Math.abs(y) ? Math.max(-120, Math.min(120, x)) : 0, y: Math.abs(y) > Math.abs(x) ? Math.max(-80, Math.min(80, y)) : 0 })
  }
  function pointerUp(event: ReactPointerEvent<HTMLDivElement>) {
    const origin = start.current
    if (!origin || origin.pointerId !== event.pointerId) return
    const x = event.clientX - origin.x
    const y = event.clientY - origin.y
    if (!origin.mode && origin.pointerType === "touch" && Math.abs(y) > Math.abs(x)) {
      const scroller = origin.scroller
      const atTop = !scroller || scroller.scrollTop <= 0
      const atBottom = !scroller || scroller.scrollTop + scroller.clientHeight >= scroller.scrollHeight - 1
      origin.mode = (y > 0 && atTop) || (y < 0 && atBottom) ? "gesture" : "scroll"
    }
    reset()
    if (origin.mode === "scroll") return
    if (Math.abs(x) > Math.abs(y) && Math.abs(x) >= SWIPE_THRESHOLD) {
      if (x > 0 && !origin.edge) onApprove()
      else if (x < 0) onDefer()
    } else if (Math.abs(y) >= SWIPE_THRESHOLD) onMove(y < 0 ? 1 : -1)
  }
  return (
    <div className="relative min-w-0 lg:contents">
      <div
        aria-label={t("gesture_surface")}
        className="touch-none motion-reduce:transform-none lg:contents"
        data-review-workspace-gesture-surface
        data-testid="mobile-review-card"
        onPointerCancel={reset}
        onPointerDown={pointerDown}
        onPointerMove={pointerMove}
        onPointerUp={pointerUp}
        style={{ transform: offset.x || offset.y ? `translate3d(${offset.x}px, ${offset.y}px, 0)` : undefined }}
      >
        {children}
      </div>
      {Boolean(offset.x || offset.y) && (
        <div aria-hidden="true" className="pointer-events-none fixed inset-x-0 top-20 z-10 text-center text-sm font-semibold text-brand lg:hidden">
          {Math.abs(offset.x) > Math.abs(offset.y)
            ? offset.x > 0
              ? t("gesture_approve")
              : t("gesture_defer")
            : offset.y < 0
              ? t("gesture_next")
              : t("gesture_previous")}
        </div>
      )}
    </div>
  )
}

function DetailsSheet({ job, payload, onClose }: { job: ReviewWorkspaceJob; payload: JobDetailPayload; onClose: () => void }) {
  const { t } = useT("review_workspace")
  const closeRef = useRef<HTMLButtonElement>(null)
  useEffect(() => {
    const previous = document.activeElement as HTMLElement | null
    closeRef.current?.focus()
    const escape = (event: KeyboardEvent) => {
      if (event.key !== "Escape") return
      event.stopImmediatePropagation()
      onClose()
    }
    window.addEventListener("keydown", escape, true)
    return () => {
      window.removeEventListener("keydown", escape, true)
      previous?.focus()
    }
  }, [onClose])
  return (
    <div className="fixed inset-0 z-[60] flex items-end bg-black/40 p-0 lg:hidden" onClick={(event) => event.target === event.currentTarget && onClose()}>
      <section
        aria-label={t("details")}
        aria-modal="true"
        className="max-h-[92dvh] w-full overflow-y-auto rounded-t-2xl bg-surface p-5 pb-[max(1.25rem,env(safe-area-inset-bottom))]"
        role="dialog"
      >
        <div className="flex items-start justify-between gap-4">
          <div>
            <p className="text-sm text-text-secondary">
              {job.slug} · {job.repository.slug}
            </p>
            <h2 className="mt-1 text-lg font-semibold">{job.title}</h2>
          </div>
          <button aria-label={t("close_details")} className="min-h-11 min-w-11 rounded border border-border p-2" onClick={onClose} ref={closeRef} type="button">
            <CloseIcon className="h-5 w-5" />
          </button>
        </div>
        <div className="mt-4">
          <CanonicalReviewWorkspace key={job.id} payload={payload} />
        </div>
      </section>
    </div>
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
  isDesktop,
  job,
  onDetail,
  onDetails,
  visualEvidenceNavigation
}: {
  conversationTarget: HTMLDivElement | null
  isDesktop: boolean
  job: ReviewWorkspaceJob
  onDetail: (jobId: number, payload: JobDetailPayload) => void
  onDetails: () => void
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
      {isDesktop ? (
        <CanonicalReviewWorkspace
          key={job.id}
          conversationPortalTarget={conversationTarget}
          payload={detail.data}
          showConversation={false}
          showEmptyVisualEvidence
          visualEvidenceNavigation={visualEvidenceNavigation}
        />
      ) : (
        <MobileReviewCard key={job.id} job={job} onDetails={onDetails} payload={detail.data} visualEvidenceNavigation={visualEvidenceNavigation} />
      )}
    </section>
  )
}

function MobileReviewCard({
  job,
  onDetails,
  payload,
  visualEvidenceNavigation
}: {
  job: ReviewWorkspaceJob
  onDetails: () => void
  payload: JobDetailPayload
  visualEvidenceNavigation?: { direction: -1 | 1; sequence: number }
}) {
  const { t } = useT("review_workspace")
  const screenshots = (payload.visual_evidence?.screenshots ?? []).filter((screenshot) => screenshot.status === "submitted")
  const [evidenceIndex, setEvidenceIndex] = useState(0)
  useEffect(() => {
    if (!visualEvidenceNavigation || screenshots.length < 2) return
    setEvidenceIndex((current) => (current + visualEvidenceNavigation.direction + screenshots.length) % screenshots.length)
  }, [screenshots.length, visualEvidenceNavigation])
  const evidence = screenshots[evidenceIndex]
  const canApprove = Boolean(payload.actions.can_approve && payload.job.summary_state.toLowerCase() === "implemented")
  return (
    <article className="space-y-4 rounded-2xl border border-border bg-surface p-4 shadow-sm" data-testid="mobile-review-summary">
      {payload.summary?.text ? (
        <Markdown className="chat-prose text-sm text-text-secondary" text={payload.summary.text} />
      ) : (
        <p className="text-sm text-text-secondary">{t("summary_unavailable")}</p>
      )}
      <section aria-label={t("visual_evidence")} className="overflow-hidden rounded-xl border border-border bg-surface-subtle">
        {evidence ? (
          <>
            <button className="block min-h-11 w-full" data-review-gesture-exempt onClick={onDetails} type="button">
              <img
                alt={evidence.page?.title || evidence.page?.path || t("visual_evidence")}
                className="max-h-[42dvh] w-full object-contain"
                src={evidence.image_url}
              />
            </button>
            <div className="flex min-h-11 items-center justify-between gap-3 px-2 py-1 text-xs text-text-secondary">
              <span className="truncate">{evidence.page?.title || evidence.page?.path || t("visual_evidence")}</span>
              <div className="flex items-center gap-1" data-review-gesture-exempt>
                {screenshots.length > 1 ? (
                  <button
                    aria-label={t("previous_evidence")}
                    className="min-h-11 min-w-11 rounded-lg border border-border"
                    onClick={() => setEvidenceIndex((current) => (current - 1 + screenshots.length) % screenshots.length)}
                    type="button"
                  >
                    ←
                  </button>
                ) : null}
                <span aria-live="polite">{t("evidence_position", { current: evidenceIndex + 1, count: screenshots.length })}</span>
                {screenshots.length > 1 ? (
                  <button
                    aria-label={t("next_evidence")}
                    className="min-h-11 min-w-11 rounded-lg border border-border"
                    onClick={() => setEvidenceIndex((current) => (current + 1) % screenshots.length)}
                    type="button"
                  >
                    →
                  </button>
                ) : null}
              </div>
            </div>
          </>
        ) : (
          <div className="grid min-h-40 place-items-center p-5 text-center text-sm text-text-secondary">{t("no_visual_evidence")}</div>
        )}
      </section>
      <div className="flex flex-wrap gap-2" aria-label={t("checks")}>
        <span
          className={`rounded-full border px-3 py-1 text-xs font-medium ${canApprove ? "border-success-border bg-success-subtle text-success-text" : "border-border text-text-secondary"}`}
        >
          {canApprove ? t("checks_ready") : t("checks_blocked")}
        </span>
        {job.pr_number ? <span className="rounded-full border border-border px-3 py-1 text-xs text-text-secondary">PR #{job.pr_number}</span> : null}
      </div>
      <div className="rounded-lg border-l-4 border-brand bg-brand-subtle p-3 text-sm text-text-secondary">
        <strong className="text-text">{t("why_needed")}</strong> {canApprove ? t("why_needed_ready") : t("why_needed_blocked")}
      </div>
      <p className="text-center text-xs text-text-secondary">{t("gesture_cue")}</p>
      <div className="rounded-lg border border-brand/30 bg-brand-subtle p-3 text-xs text-text-secondary" data-testid="mobile-gesture-coach">
        {t("gesture_coach")}
      </div>
    </article>
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
  setConversationTarget,
  gestureIntent,
  isDesktop
}: {
  detail?: JobDetailPayload
  job: ReviewWorkspaceJob
  onCompleted: () => void
  onDefer: () => void
  onEvidenceMove: (direction: -1 | 1) => void
  onExit: () => void
  onMove: (offset: number) => void
  setConversationTarget: (target: HTMLDivElement | null) => void
  gestureIntent?: { jobId: number; sequence: number }
  isDesktop: boolean
}) {
  const { t } = useT("review_workspace")
  const queryClient = useQueryClient()
  const [feedbackOpen, setFeedbackOpen] = useState(false)
  const [feedback, setFeedback] = useState("")
  const [confirming, setConfirming] = useState(false)
  const handledGestureSequence = useRef<number>()
  useEffect(() => {
    setConfirming(false)
    setFeedbackOpen(false)
    setFeedback("")
  }, [job.id])
  async function completed() {
    await queryClient.invalidateQueries({ queryKey: ["review_workspace"] })
    await queryClient.invalidateQueries({ queryKey: ["jobs", String(job.id)] })
    onCompleted()
  }
  const canApprove = Boolean(detail?.actions.can_approve && detail.job.summary_state.toLowerCase() === "implemented" && detail.paths.app_approve_path)
  const refreshEligibility = () => queryClient.invalidateQueries({ queryKey: ["review_workspace"] })
  const approve = useMutation({
    mutationFn: () => postJobCommand(detail!.paths.app_approve_path, { expected_revision: job.revision }),
    onError: refreshEligibility,
    onSuccess: completed
  })
  const submitFeedback = useMutation({
    mutationFn: () => submitJobFeedback(job.id, feedback.trim(), job.revision),
    onError: refreshEligibility,
    onSuccess: completed
  })
  useEffect(() => {
    const shortcut = (event: KeyboardEvent) => {
      if (event.key !== "Escape" && (event.target instanceof HTMLInputElement || event.target instanceof HTMLTextAreaElement)) return
      const key = event.key.toLowerCase()
      if (key === "a" && canApprove) setConfirming(true)
      if (key === "f") setFeedbackOpen(true)
      if (key === "j") onMove(1)
      if (key === "k") onMove(-1)
      if (event.key === "ArrowLeft") onEvidenceMove(-1)
      if (event.key === "ArrowRight") onEvidenceMove(1)
      if (event.key === "Escape") {
        if (feedbackOpen) setFeedbackOpen(false)
        else if (confirming) setConfirming(false)
        else onExit()
      }
    }
    window.addEventListener("keydown", shortcut)
    return () => window.removeEventListener("keydown", shortcut)
  }, [canApprove, confirming, feedbackOpen, onEvidenceMove, onExit, onMove])
  useEffect(() => {
    if (gestureIntent?.jobId !== job.id || !canApprove || handledGestureSequence.current === gestureIntent.sequence) return
    handledGestureSequence.current = gestureIntent.sequence
    setConfirming(true)
  }, [canApprove, gestureIntent, job.id])
  const mutationError = approve.error ?? submitFeedback.error
  return (
    <aside
      aria-label={t("decision_context")}
      className="border-l border-border bg-surface p-5 max-lg:border-0 max-lg:bg-transparent max-lg:p-0 max-lg:pb-28 lg:overflow-y-auto"
    >
      <div className="hidden lg:block">
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
      </div>
      <div className={MOBILE_ACTION_BAR_CLASS}>
        {confirming ? (
          <div className="col-span-3 rounded border border-brand/30 bg-brand-subtle p-3 max-lg:order-2">
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
          <Button className="w-full max-lg:order-2 max-lg:col-span-2 max-lg:min-h-11" disabled={!canApprove} onClick={() => setConfirming(true)} variant="primary">
            {t(isDesktop ? "approve_shortcut" : "approve_mobile")}
          </Button>
        )}
        <Button aria-label={t("feedback")} className="w-full max-lg:order-3 max-lg:min-h-11" onClick={() => setFeedbackOpen(true)} variant="secondary">
          <span className="max-lg:hidden">{t(isDesktop ? "feedback_shortcut" : "feedback")}</span>
          <FeedbackIcon className="hidden size-5 max-lg:block" />
        </Button>
        <Button aria-label={t("defer")} className="w-full max-lg:order-1 max-lg:min-h-11" onClick={onDefer} variant="secondary">
          <span className="max-lg:hidden">{t("defer")}</span>
          <DeferToQueueEndIcon className="hidden size-5 max-lg:block" />
        </Button>
      </div>
      {feedbackOpen ? (
        <form
          aria-label={t("feedback")}
          className={MOBILE_FEEDBACK_SHEET_CLASS}
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
      {isDesktop ? <p className="mt-5 text-xs text-text-secondary">{t("shortcuts")}</p> : null}
    </aside>
  )
}

function DeferToQueueEndIcon({ className }: { className: string }) {
  return (
    <svg aria-hidden="true" className={className} fill="none" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="2" viewBox="0 0 24 24">
      <path d="M5 7h9a5 5 0 0 1 5 5v1" />
      <path d="m16 10 3 3 3-3" />
      <path d="M5 12h6M5 17h10" />
    </svg>
  )
}

function FeedbackIcon({ className }: { className: string }) {
  return (
    <svg aria-hidden="true" className={className} fill="none" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="2" viewBox="0 0 24 24">
      <path d="M20 15a3 3 0 0 1-3 3H9l-5 3v-6a3 3 0 0 1-1-2V7a3 3 0 0 1 3-3h11a3 3 0 0 1 3 3Z" />
    </svg>
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
