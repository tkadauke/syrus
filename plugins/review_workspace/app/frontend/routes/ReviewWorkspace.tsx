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
import { Link, Navigate, useLocation, useNavigate, useNavigationType, useParams } from "react-router-dom"
import { fetchReviewWorkspace, type ReviewWorkspaceJob } from "../api/reviewWorkspace"

const WORKSPACE_SCROLL_CLASS =
  "h-[calc(100dvh-4rem)] shrink-0 overflow-x-hidden overflow-y-scroll overscroll-contain [-webkit-overflow-scrolling:touch] lg:grid lg:h-auto lg:min-h-0 lg:flex-1 lg:grid-cols-[17rem_minmax(0,1fr)_20rem] lg:overflow-hidden"
const MOBILE_ACTION_BAR_CLASS =
  "mt-5 space-y-2 max-lg:fixed max-lg:inset-x-3 max-lg:bottom-[max(.75rem,env(safe-area-inset-bottom))] max-lg:z-20 max-lg:grid max-lg:grid-cols-4 max-lg:gap-2 max-lg:space-y-0 max-lg:rounded-xl max-lg:border max-lg:border-border max-lg:bg-surface/95 max-lg:p-2 max-lg:shadow-lg max-lg:backdrop-blur"
const MOBILE_FEEDBACK_SHEET_CLASS =
  "mt-4 space-y-2 max-lg:fixed max-lg:inset-x-0 max-lg:bottom-0 max-lg:z-30 max-lg:rounded-t-2xl max-lg:border max-lg:border-border max-lg:bg-surface max-lg:p-5 max-lg:pb-[max(1.25rem,env(safe-area-inset-bottom))] max-lg:shadow-xl"
const MOBILE_DETAILS_SHEET_CLASS =
  "max-h-[92dvh] w-full min-w-0 max-w-full overflow-x-hidden overflow-y-auto rounded-t-2xl bg-surface p-5 pb-[max(1.25rem,env(safe-area-inset-bottom))]"
const MOBILE_EVIDENCE_CAROUSEL_CLASS =
  "flex w-full snap-x snap-mandatory overflow-x-auto overscroll-x-contain touch-pan-x touch-pan-y [scrollbar-width:none] [&::-webkit-scrollbar]:hidden"
const MOBILE_GESTURE_ACTION_CLASS =
  "flex shrink-0 items-center justify-center gap-1.5 whitespace-nowrap rounded-xl border border-brand/20 bg-brand-subtle text-center"
const MAX_CARD_ROTATION_DEGREES = 4
const REVIEW_SESSION_STATE_KEY = "reviewWorkspaceCanReturn"

function canReturnFromState(state: unknown) {
  return Boolean(state && typeof state === "object" && (state as Record<string, unknown>)[REVIEW_SESSION_STATE_KEY] === true)
}

export default function ReviewWorkspaceRoute() {
  const { t } = useT("review_workspace")
  const location = useLocation()
  const navigate = useNavigate()
  const entryNavigationType = useNavigationType()
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
  const canReturnToEntry = useRef(canReturnFromState(location.state) || entryNavigationType === "PUSH")
  const sessionState = { [REVIEW_SESSION_STATE_KEY]: canReturnToEntry.current }
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
    if (canReturnToEntry.current) navigate(-1)
    else navigate(withRoutePrefix("/dashboard/jobs", prefix), { replace: true })
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
  if (location.pathname !== canonicalPath) return <Navigate replace state={sessionState} to={canonicalPath} />
  const selectJob = (offset: number) =>
    navigate(withRoutePrefix(`/review/${jobs[(jobs.indexOf(active) + offset + jobs.length) % jobs.length].slug}`, prefix), {
      replace: true,
      state: sessionState
    })

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
                onClick={() => selectJob(-1)}
                type="button"
              >
                ↑
              </button>
              <button
                aria-label={t("next_job")}
                className="min-h-11 min-w-11 rounded border border-border bg-surface px-2 text-sm lg:hidden"
                onClick={() => selectJob(1)}
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
        <JobRail active={active} jobs={jobs} prefix={prefix} sessionState={sessionState} />
        <MobileGestureSurface
          onApprove={() => setGestureIntent((current) => ({ jobId: active.id, sequence: (current?.sequence ?? 0) + 1 }))}
          onDefer={() => setDeferred((current) => new Set(current).add(active.id))}
          onDetails={() => setDetailsJobId(active.id)}
          onMove={selectJob}
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
          onMove={selectJob}
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
// Touch intent needs enough travel to absorb finger jitter, while this ratio
// lets deliberate diagonal swipes resolve without requiring a straight line.
const GESTURE_ACTIVATION_DISTANCE = 16
const GESTURE_AXIS_DOMINANCE = 1.25
const LONG_PRESS_MS = 550

type GestureDirection = "left" | "right" | "up" | "down"
type GestureMode = "pending" | "gesture" | "scroll" | "invalid"

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
    mode: GestureMode
    direction?: GestureDirection
    armed: boolean
    scrollOnly: boolean
    scroller: HTMLElement | null
  }>()
  const longPress = useRef<number>()
  const [offset, setOffset] = useState({ x: 0, y: 0 })
  const [dragging, setDragging] = useState(false)
  const clearLongPress = () => {
    if (longPress.current) window.clearTimeout(longPress.current)
    longPress.current = undefined
  }
  const reset = () => {
    clearLongPress()
    start.current = undefined
    setDragging(false)
    setOffset({ x: 0, y: 0 })
  }
  function pointerDown(event: ReactPointerEvent<HTMLDivElement>) {
    if (window.innerWidth >= 1024) return
    if (event.pointerType === "mouse" && event.button !== 0) return
    const target = event.target as HTMLElement
    if (target.closest("[data-review-gesture-exempt]")) return
    const scrollOnly = Boolean(target.closest("button, a, input, textarea, [role='button']"))
    if (scrollOnly && event.pointerType !== "touch") return
    const edge = event.clientX < 28 || event.clientX > window.innerWidth - 28
    start.current = {
      x: event.clientX,
      y: event.clientY,
      lastY: event.clientY,
      pointerId: event.pointerId,
      pointerType: event.pointerType,
      edge,
      mode: "pending",
      armed: false,
      scrollOnly,
      scroller: event.currentTarget.closest<HTMLElement>("[data-review-workspace-scroll-container]")
    }
    setDragging(true)
    target.setPointerCapture?.(event.pointerId)
    if (!scrollOnly) {
      longPress.current = window.setTimeout(() => {
        if (!start.current) return
        reset()
        onDetails()
      }, LONG_PRESS_MS)
    }
  }
  function pointerMove(event: ReactPointerEvent<HTMLDivElement>) {
    const origin = start.current
    if (!origin || origin.pointerId !== event.pointerId) return
    const x = event.clientX - origin.x
    const y = event.clientY - origin.y
    const absoluteX = Math.abs(x)
    const absoluteY = Math.abs(y)
    if (absoluteX > GESTURE_ACTIVATION_DISTANCE || absoluteY > GESTURE_ACTIVATION_DISTANCE) clearLongPress()
    if (origin.mode === "pending" && (absoluteX >= GESTURE_ACTIVATION_DISTANCE || absoluteY >= GESTURE_ACTIVATION_DISTANCE)) {
      const horizontal = absoluteX >= absoluteY * GESTURE_AXIS_DOMINANCE
      const vertical = absoluteY >= absoluteX * GESTURE_AXIS_DOMINANCE
      if (!horizontal && !vertical) return

      origin.direction = horizontal ? (x > 0 ? "right" : "left") : y > 0 ? "down" : "up"
      if (origin.scrollOnly) {
        origin.mode = vertical ? "scroll" : "invalid"
      } else if (origin.edge && origin.direction === "right") {
        origin.mode = "invalid"
        clearLongPress()
        return
      } else if (vertical && origin.pointerType === "touch") {
        const scroller = origin.scroller
        const atTop = !scroller || scroller.scrollTop <= 0
        const atBottom = !scroller || scroller.scrollTop + scroller.clientHeight >= scroller.scrollHeight - 1
        origin.mode = (origin.direction === "down" && atTop) || (origin.direction === "up" && atBottom) ? "gesture" : "scroll"
      } else origin.mode = "gesture"
    }
    if (origin.mode === "scroll" && origin.scroller) {
      event.preventDefault()
      origin.scroller.scrollTop += origin.lastY - event.clientY
      origin.lastY = event.clientY
      return
    }
    if (origin.mode !== "gesture" || !origin.direction) return
    event.preventDefault()
    const horizontal = origin.direction === "left" || origin.direction === "right"
    const signedDistance = horizontal ? (origin.direction === "right" ? x : -x) : origin.direction === "down" ? y : -y
    if (signedDistance >= SWIPE_THRESHOLD) origin.armed = true
    const distance = Math.max(0, signedDistance)
    setOffset(
      horizontal
        ? { x: Math.min(120, distance) * (origin.direction === "right" ? 1 : -1), y: 0 }
        : { x: 0, y: Math.min(80, distance) * (origin.direction === "down" ? 1 : -1) }
    )
  }
  function pointerUp(event: ReactPointerEvent<HTMLDivElement>) {
    const origin = start.current
    if (!origin || origin.pointerId !== event.pointerId) return
    reset()
    if (origin.mode !== "gesture" || !origin.armed) return
    if (origin.direction === "right") onApprove()
    else if (origin.direction === "left") onDefer()
    else onMove(origin.direction === "up" ? 1 : -1)
  }
  const reducedMotion = window.matchMedia?.("(prefers-reduced-motion: reduce)").matches
  const horizontal = Math.abs(offset.x) > Math.abs(offset.y)
  const rotation = horizontal && !reducedMotion ? Math.max(-MAX_CARD_ROTATION_DEGREES, Math.min(MAX_CARD_ROTATION_DEGREES, offset.x / 30)) : 0
  const gesture = horizontal
    ? offset.x > 0
      ? { action: t("gesture_action_approve"), consequence: t("gesture_approve"), direction: "right" as const }
      : { action: t("gesture_action_defer"), consequence: t("gesture_defer"), direction: "left" as const }
    : offset.y < 0
      ? { action: t("gesture_action_next"), consequence: t("gesture_next"), direction: "up" as const }
      : { action: t("gesture_action_previous"), consequence: t("gesture_previous"), direction: "down" as const }
  const progress = Math.min(1, (horizontal ? Math.abs(offset.x) : Math.abs(offset.y)) / SWIPE_THRESHOLD)
  const cueStyle = reducedMotion ? undefined : { opacity: 0.2 + progress * 0.8, transform: `scale(${0.88 + progress * 0.12})` }
  const cardTransform =
    !reducedMotion && (offset.x || offset.y) ? `translate3d(${offset.x}px, ${offset.y}px, 0)${rotation ? ` rotate(${rotation}deg)` : ""}` : undefined
  return (
    <div className="relative isolate min-w-0 overflow-hidden lg:contents lg:overflow-visible">
      {Boolean(offset.x || offset.y) && (
        <div
          aria-label={gesture.consequence}
          className={`pointer-events-none absolute z-20 flex font-semibold text-brand lg:hidden ${
            horizontal
              ? `inset-y-0 w-[min(8.5rem,calc(100vw_-_1rem))] items-center ${offset.x > 0 ? "left-[max(.5rem,env(safe-area-inset-left))]" : "right-[max(.5rem,env(safe-area-inset-right))]"}`
              : `inset-x-0 p-5 text-sm ${offset.y < 0 ? "bottom-0 justify-center" : "top-0 justify-center"}`
          }`}
          data-gesture-direction={gesture.direction}
          data-testid="mobile-gesture-reveal"
          role="status"
        >
          <span
            aria-hidden="true"
            className={`${MOBILE_GESTURE_ACTION_CLASS} ${horizontal ? "w-full gap-1 px-1.5 py-2 text-xs" : "w-[min(12rem,70vw)] px-3 py-2"}`}
            data-testid="mobile-gesture-action"
            style={cueStyle}
          >
            <GestureDirectionIcon direction={gesture.direction} />
            {gesture.action}
          </span>
        </div>
      )}
      <div
        aria-label={t("gesture_surface")}
        className={`relative z-10 motion-reduce:transform-none lg:contents ${dragging ? "" : "motion-safe:transition-transform motion-safe:duration-200"}`}
        data-review-workspace-gesture-surface
        data-testid="mobile-review-card"
        onPointerCancel={reset}
        onLostPointerCapture={reset}
        onPointerDown={pointerDown}
        onPointerMove={pointerMove}
        onPointerUp={pointerUp}
        style={{
          transform: cardTransform,
          transformOrigin: "50% 75%"
        }}
      >
        {children}
      </div>
    </div>
  )
}

function GestureDirectionIcon({ direction }: { direction: "left" | "right" | "up" | "down" }) {
  const rotation = { right: "", left: "rotate-180", up: "-rotate-90", down: "rotate-90" }[direction]
  return (
    <svg aria-hidden="true" className={`h-3.5 w-3.5 shrink-0 ${rotation}`} fill="none" viewBox="0 0 20 20">
      <path d="M4 10h11m-4-4 4 4-4 4" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="2" />
    </svg>
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
    <div
      className="fixed inset-0 z-[60] flex w-full max-w-full items-end overflow-x-hidden bg-black/40 p-0 lg:hidden"
      data-testid="mobile-details-backdrop"
      onClick={(event) => event.target === event.currentTarget && onClose()}
    >
      <section aria-label={t("details")} aria-modal="true" className={MOBILE_DETAILS_SHEET_CLASS} data-testid="mobile-details-sheet" role="dialog">
        <div className="flex w-full min-w-0 max-w-full items-start justify-between gap-4">
          <div className="min-w-0 max-w-full flex-1">
            <p className="break-all text-sm text-text-secondary">
              {job.slug} · {job.repository.slug}
            </p>
            <h2 className="mt-1 break-words text-lg font-semibold">{job.title}</h2>
          </div>
          <button aria-label={t("close_details")} className="min-h-11 min-w-11 rounded border border-border p-2" onClick={onClose} ref={closeRef} type="button">
            <CloseIcon className="h-5 w-5" />
          </button>
        </div>
        <div className="mt-4 w-full min-w-0 max-w-full" data-testid="mobile-details-content">
          <CanonicalReviewWorkspace key={job.id} payload={payload} />
        </div>
      </section>
    </div>
  )
}

function JobRail({
  active,
  jobs,
  prefix,
  sessionState
}: {
  active: ReviewWorkspaceJob
  jobs: ReviewWorkspaceJob[]
  prefix: string
  sessionState: Record<string, boolean>
}) {
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
            replace
            state={sessionState}
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
      <div className="mb-5 touch-none">
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
  const carouselRef = useRef<HTMLDivElement>(null)
  const settleTimerRef = useRef<number>()
  const handledEvidenceNavigationRef = useRef<number>()

  const settleEvidencePosition = useCallback(() => {
    const carousel = carouselRef.current
    if (!carousel || carousel.clientWidth <= 0) return
    const nextIndex = Math.max(0, Math.min(screenshots.length - 1, Math.round(carousel.scrollLeft / carousel.clientWidth)))
    setEvidenceIndex(nextIndex)
  }, [screenshots.length])

  const handleCarouselScroll = useCallback(() => {
    if (settleTimerRef.current) window.clearTimeout(settleTimerRef.current)
    settleTimerRef.current = window.setTimeout(settleEvidencePosition, 80)
  }, [settleEvidencePosition])

  const scrollToEvidence = useCallback(
    (index: number, behavior: ScrollBehavior = "smooth") => {
      const carousel = carouselRef.current
      if (!carousel || screenshots.length === 0) return
      const nextIndex = (index + screenshots.length) % screenshots.length
      const reducedMotion = window.matchMedia?.("(prefers-reduced-motion: reduce)").matches
      carousel.scrollTo({ left: nextIndex * carousel.clientWidth, behavior: reducedMotion ? "auto" : behavior })
    },
    [screenshots.length]
  )

  useEffect(() => {
    if (!visualEvidenceNavigation || screenshots.length < 2 || handledEvidenceNavigationRef.current === visualEvidenceNavigation.sequence) return
    handledEvidenceNavigationRef.current = visualEvidenceNavigation.sequence
    scrollToEvidence(evidenceIndex + visualEvidenceNavigation.direction)
  }, [evidenceIndex, screenshots.length, scrollToEvidence, visualEvidenceNavigation])
  useEffect(() => {
    const carousel = carouselRef.current
    if (!carousel) return
    const preservePosition = () => carousel.scrollTo({ left: evidenceIndex * carousel.clientWidth, behavior: "auto" })
    const observer = typeof ResizeObserver === "undefined" ? null : new ResizeObserver(preservePosition)
    observer?.observe(carousel)
    window.addEventListener("resize", preservePosition)
    return () => {
      if (settleTimerRef.current) window.clearTimeout(settleTimerRef.current)
      observer?.disconnect()
      window.removeEventListener("resize", preservePosition)
    }
  }, [evidenceIndex])
  const evidence = screenshots[evidenceIndex]
  const canApprove = Boolean(payload.actions.can_approve && payload.job.summary_state.toLowerCase() === "implemented")
  return (
    <article className="relative space-y-4 rounded-2xl border border-border bg-surface p-4 shadow-sm" data-testid="mobile-review-summary">
      {/* Gesture-start regions disable native panning so the pending lock owns
          arbitration. The evidence section remains exempt and keeps native pan. */}
      <div aria-hidden="true" className="absolute inset-0 touch-none" data-testid="mobile-decision-touch-region" />
      <div className="relative z-10 touch-none">
        {payload.summary?.text ? (
          <Markdown className="chat-prose text-sm text-text-secondary" text={payload.summary.text} />
        ) : (
          <p className="text-sm text-text-secondary">{t("summary_unavailable")}</p>
        )}
      </div>
      <section
        aria-label={t("visual_evidence")}
        className={`relative z-10 overflow-hidden rounded-xl border border-border bg-surface-subtle ${evidence ? "" : "touch-none"}`}
        data-review-gesture-exempt={evidence ? "true" : undefined}
      >
        {evidence ? (
          <>
            <div data-review-gesture-exempt>
              <div
                aria-label={t("visual_evidence_carousel")}
                className={MOBILE_EVIDENCE_CAROUSEL_CLASS}
                data-testid="mobile-evidence-carousel"
                onScroll={handleCarouselScroll}
                ref={carouselRef}
                role="region"
              >
                {screenshots.map((screenshot) => (
                  <button className="block min-h-11 w-full shrink-0 snap-center" key={screenshot.id} onClick={onDetails} type="button">
                    <img
                      alt={screenshot.page?.title || screenshot.page?.path || t("visual_evidence")}
                      className="max-h-[42dvh] w-full object-contain"
                      src={screenshot.image_url}
                    />
                  </button>
                ))}
              </div>
              {screenshots.length > 1 ? (
                <div aria-label={t("visual_evidence_pagination")} className="flex min-h-8 items-center justify-center gap-2 px-2" role="group">
                  {screenshots.map((screenshot, index) => (
                    <button
                      aria-label={t("show_visual_evidence", { current: index + 1, count: screenshots.length })}
                      aria-pressed={index === evidenceIndex}
                      className={`h-2.5 w-2.5 rounded-full border ${index === evidenceIndex ? "scale-125 border-brand bg-brand" : "border-text-muted bg-transparent"}`}
                      key={screenshot.id}
                      onClick={() => scrollToEvidence(index)}
                      type="button"
                    />
                  ))}
                </div>
              ) : null}
            </div>
            <div className="flex min-h-11 items-center px-2 py-1 text-xs text-text-secondary" data-testid="mobile-evidence-caption">
              <span className="truncate">{evidence.page?.title || evidence.page?.path || t("visual_evidence")}</span>
              <span aria-live="polite" className="sr-only">
                {t("evidence_position", { current: evidenceIndex + 1, count: screenshots.length })}
              </span>
            </div>
          </>
        ) : (
          <div className="grid min-h-40 place-items-center p-5 text-center text-sm text-text-secondary">{t("no_visual_evidence")}</div>
        )}
      </section>
      <div className="relative z-10 space-y-4 touch-none">
        <div className="flex flex-wrap gap-2" aria-label={t("checks")}>
          <span
            className={`rounded-full border px-3 py-1 text-xs font-medium ${canApprove ? "border-success-border bg-success-subtle text-success-text" : "border-border text-text-secondary"}`}
          >
            {canApprove ? t("checks_ready") : t("checks_blocked")}
          </span>
          {job.pr_number ? (
            <span className="rounded-full border border-border px-3 py-1 text-xs text-text-secondary">
              {t("pull_request_number", { number: job.pr_number })}
            </span>
          ) : null}
        </div>
        <div className="rounded-lg border-l-4 border-brand bg-brand-subtle p-3 text-sm text-text-secondary">
          <strong className="text-text">{t("why_needed")}</strong> {canApprove ? t("why_needed_ready") : t("why_needed_blocked")}
        </div>
        <p className="text-center text-xs text-text-secondary">{t("gesture_cue")}</p>
        <div className="rounded-lg border border-brand/30 bg-brand-subtle p-3 text-xs text-text-secondary" data-testid="mobile-gesture-coach">
          {t("gesture_coach")}
        </div>
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
  const approvalStarted = useRef(false)
  useEffect(() => {
    approvalStarted.current = false
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
    onSuccess: completed,
    onSettled: () => {
      approvalStarted.current = false
    }
  })
  const requestApproval = () => {
    if (approvalStarted.current) return
    approvalStarted.current = true
    approve.mutate()
  }
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
        {confirming && isDesktop ? (
          <div className="col-span-3 rounded border border-brand/30 bg-brand-subtle p-3 max-lg:order-2">
            <p className="text-sm font-medium">{t("approve_confirm", { slug: job.slug })}</p>
            <div className="mt-3 flex gap-2">
              <Button disabled={approve.isPending} onClick={() => setConfirming(false)} variant="secondary">
                {t("common:cancel")}
              </Button>
              <Button disabled={approve.isPending} onClick={requestApproval} variant="primary">
                {t("approve")}
              </Button>
            </div>
          </div>
        ) : (
          <Button
            className="w-full max-lg:order-2 max-lg:col-span-2 max-lg:min-h-11"
            disabled={!canApprove}
            onClick={() => setConfirming(true)}
            variant="primary"
          >
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
      {confirming && !isDesktop ? (
        <ApprovalSheet
          inProgress={approve.isPending}
          job={job}
          onApprove={requestApproval}
          onClose={() => {
            if (!approve.isPending) setConfirming(false)
          }}
        />
      ) : null}
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

function ApprovalSheet({ inProgress, job, onApprove, onClose }: { inProgress: boolean; job: ReviewWorkspaceJob; onApprove: () => void; onClose: () => void }) {
  const { t } = useT("review_workspace")
  const cancelRef = useRef<HTMLButtonElement>(null)
  const closeRef = useRef(onClose)
  const inProgressRef = useRef(inProgress)
  closeRef.current = onClose
  inProgressRef.current = inProgress
  useEffect(() => {
    const previous = document.activeElement as HTMLElement | null
    const previousOverflow = document.body.style.overflow
    document.body.style.overflow = "hidden"
    cancelRef.current?.focus()
    const escape = (event: KeyboardEvent) => {
      if (event.key !== "Escape" || inProgressRef.current) return
      event.stopImmediatePropagation()
      closeRef.current()
    }
    window.addEventListener("keydown", escape, true)
    return () => {
      window.removeEventListener("keydown", escape, true)
      document.body.style.overflow = previousOverflow
      previous?.focus()
    }
  }, [])
  return (
    <div
      className="fixed inset-0 z-[70] flex items-end bg-black/50"
      data-testid="mobile-approval-backdrop"
      onClick={(event) => event.target === event.currentTarget && !inProgress && onClose()}
    >
      <section
        aria-busy={inProgress}
        aria-labelledby="mobile-approval-title"
        aria-modal="true"
        className="w-full rounded-t-2xl border border-border bg-surface px-5 pb-[max(1.25rem,env(safe-area-inset-bottom))] pt-3 shadow-xl"
        data-testid="mobile-approval-sheet"
        role="dialog"
      >
        <div aria-hidden="true" className="mx-auto mb-4 h-1 w-10 rounded-full bg-border" />
        <h2 className="text-lg font-semibold" id="mobile-approval-title">
          {t("approve_confirm", { slug: job.slug })}
        </h2>
        <p className="mt-2 text-sm text-text-secondary">{t("approve_consequence")}</p>
        <div className="mt-5 grid grid-cols-2 gap-2">
          <Button disabled={inProgress} onClick={onClose} ref={cancelRef} type="button" variant="secondary">
            {t("common:cancel")}
          </Button>
          <Button disabled={inProgress} onClick={onApprove} type="button" variant="primary">
            {inProgress ? t("approving") : t("approve")}
          </Button>
        </div>
      </section>
    </div>
  )
}

function DeferToQueueEndIcon({ className }: { className: string }) {
  return (
    <svg
      aria-hidden="true"
      className={className}
      fill="none"
      stroke="currentColor"
      strokeLinecap="round"
      strokeLinejoin="round"
      strokeWidth="2"
      viewBox="0 0 24 24"
    >
      <path d="M5 7h9a5 5 0 0 1 5 5v1" />
      <path d="m16 10 3 3 3-3" />
      <path d="M5 12h6M5 17h10" />
    </svg>
  )
}

function FeedbackIcon({ className }: { className: string }) {
  return (
    <svg
      aria-hidden="true"
      className={className}
      fill="none"
      stroke="currentColor"
      strokeLinecap="round"
      strokeLinejoin="round"
      strokeWidth="2"
      viewBox="0 0 24 24"
    >
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
