import { RelativeTimestamp } from "../components/RelativeTimestamp"
import { DeploymentStagePipeline } from "../components/DeploymentStagePipeline"
import { keepPreviousData, useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { subscribeToJobResourceEvents } from "../lib/actionCable"
import type { FormEvent, ReactNode } from "react"
import { useEffect, useMemo, useRef, useState } from "react"
import { Link, useLocation, useNavigate, useParams } from "react-router-dom"
import { useT } from "../hooks/useT"
import { usePageTitle } from "../hooks/usePageTitle"
import { KeyValue } from "../components/KeyValue"
import { ChevronIcon } from "../components/ChevronIcon"
import { PageHeading, SectionHeading } from "../components/Heading"
import { CopyableSlug } from "../components/CopyableSlug"
import { SlugHoverCard } from "../components/SlugHoverCard"
import { NoticeToast } from "../components/NoticeToast"
import { StatusPill, TonePill } from "../components/StatusPill"
import { StartBlockedReasonPill } from "../components/StartBlockedReasonPill"
import { Markdown } from "../lib/Markdown"
import { translateBlockedReason } from "../lib/translateBlockedReason"
import { workflowSlug } from "../lib/slugs"
import { Button } from "../components/Button"
import { Input } from "../components/Input"
import { Select } from "../components/Select"
import {
  applyPendingFeedback,
  createJobAttachments,
  deleteJobCommand,
  fetchJobDependencyOptions,
  fetchJobDetail,
  fetchJobWorkflows,
  ignorePendingFeedback,
  openJobInCodingMode,
  replacePendingFeedback,
  retryPendingFeedback,
  stopPreview as stopPreviewRequest,
  submitJobFeedback,
  updateJobPriority,
  updateJobProviderSetting,
  type JobApprovalEvidence,
  type JobApprovalRecord,
  type JobApprovalStatus,
  type JobDeploymentStage,
  type JobDetailPayload,
  type JobPrCheckAttribution,
  type JobTestPlan,
  type JobWorkflow,
  type PendingFeedbackComment
} from "../api/jobs"
import type { TypedArtifact } from "../api/artifacts"
import { CoverageCard } from "../components/CoverageCard"
import { PluginUiSlot, type UiSlotPanel } from "../pluginUiSlots"
import { ProviderAvailabilityWarning, providerFailoverTooltip } from "../components/ProviderAvailabilityWarning"
import { SyrusTour } from "../components/SyrusTour"
import { useTour } from "../hooks/useTour"
import { errorMessage } from "../lib/errorMessage"
import type { JobDetailQueryKey, JobTab, JobWorkflowsQueryKey } from "./jobDetail/queryKeys"
import { CommandButton, useJobCommand, type JobCommand } from "./jobDetail/command"
import {
  TagsPanel,
  NeedsAttentionBanner,
  TriageDecisionBanner,
  FeedbackSourceBadge,
  EpicSummaryLink,
  TimelinePanel,
  AttachmentPreview,
  AttachmentCard,
  MergeablePill,
  JobStateBadge,
  PendingJobTitle,
  JobSourceLink,
  DependencyLink,
  JobDependencyTargetReference,
  PanelMessage,
  SmallPill,
  jobSourceLabel
} from "./jobDetail/components"
import { DeliveryPanel, deliveryPanelRelevant } from "./jobDetail/Delivery"
import { canSubmitFeedbackDirectly, ChatBubbleIcon, HeaderActions, JobFeedbackPanel } from "./jobDetail/JobHeader"
import { PreviewPanel, PreviewStopModal } from "../components/PreviewPanel"
import {
  diffRefsFromLocation,
  jobDetailQueryKey,
  jobDetailSearch,
  jobWorkflowsQueryKey,
  mergeJobWorkflowsPayload,
  tabFromLocation
} from "./jobDetail/queryKeys"
import { formatCurrency, jobSlug, withRoutePrefix } from "./jobDetail/formatting"
import { ArtifactBody, TypedArtifactPanel } from "../components/artifacts/TypedArtifactPanel"
import { WorkflowsTab } from "./jobDetail/WorkflowGraph"
import { AgentConversationTab } from "./jobDetail/AgentConversation"
import { TimelineTab } from "./jobDetail/Timeline"
import { SourceTab } from "./jobDetail/SourceBrowser"
import { ReviewWorkspace } from "./jobDetail/ReviewWorkspace"
import { ReportTab } from "./jobDetail/Report"
import { JobTargetGraphPanel } from "./RepositoryTargetGraph"
import { diffReviewFeedbackAllowed } from "./jobDetail/DiffReviewFeedback"
import { useBugReportTrigger } from "../lib/bugReportContext"
import { jobWorkflowContextBugReportAttachment } from "./jobDetail/bugReportWorkflowContext"
import { scheduleJobDetailInvalidation } from "../lib/appEvents"
import { Notice, Page, Section } from "../components/ui"
import {
  jobNavigationHref,
  navigationIndex,
  readJobNavigationContext,
  storeJobNavigationContext,
  withUpdatedNavigationItemState,
  type JobNavigationContext
} from "../lib/jobNavigationContext"
import { MetadataLine, OwnerBadge } from "./dashboard/components"
import { UnderlineTabs } from "../components/Tabs"
import { normalizeJobDetailPayload } from "../lib/entityStore"

export function JobDetailRoute() {
  const { t } = useT("jobs")
  const params = useParams()
  const location = useLocation()
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const id = params.id || ""
  const initialDiff = diffRefsFromLocation(location.search)
  const prefix = location.pathname.startsWith("/app-shell") ? "/app-shell" : ""
  const detailSearch = jobDetailSearch(location.search)
  const queryKey = jobDetailQueryKey(id, detailSearch)
  const workflowsQueryKey = jobWorkflowsQueryKey(id, detailSearch)

  // Job-scoped Action Cable subscription: only an actively-viewed Job's
  // detailed Workflow/Step/Run events reach this tab (see JobChannel). Route
  // changes (navigating to a different Job, or away from this page) release
  // the subscription via this effect's cleanup.
  useEffect(() => {
    if (!id) return

    const subscription = subscribeToJobResourceEvents(id, queryClient)
    return () => subscription.unsubscribe()
  }, [ id, queryClient ])

  const detail = useQuery({
    queryKey,
    queryFn: async () => normalizeJobDetailPayload(await fetchJobDetail(id, detailSearch)),
    enabled: id.length > 0
  })
  const pluginTabKeys = (detail.data?.ui_tabs ?? []).map((tab) => tab.key).filter((key): key is string => Boolean(key))
  const activeTab = tabFromLocation(location.pathname, location.search, pluginTabKeys)
  const workflows = useQuery({
    queryKey: workflowsQueryKey,
    queryFn: async () => {
      const payload = await fetchJobWorkflows(id, detailSearch)
      if (detail.data) normalizeJobDetailPayload(mergeJobWorkflowsPayload(detail.data, payload), "job_workflows")
      return payload
    },
    enabled: id.length > 0 && (activeTab === "workflows" || activeTab === "timeline") && detail.isSuccess,
    placeholderData: keepPreviousData
  })
  const payload = detail.isSuccess ? mergeJobWorkflowsPayload(detail.data, workflows.isPlaceholderData ? undefined : workflows.data) : null
  const job = detail.data?.job
  const pageTitle = job ? (job.issue_title ? `${jobSlug(job.id)}: ${job.issue_title}` : jobSlug(job.id)) : id ? `JOB-${id}` : undefined
  usePageTitle(pageTitle)

  function selectTab(tab: JobTab) {
    const search = new URLSearchParams(location.search)
    if (tab === "summary") search.delete("tab")
    else search.set("tab", tab)
    if (tab !== "workflows") search.delete("workflows_page")
    const next = search.toString()
    navigate(`${location.pathname}${next ? `?${next}` : ""}`)
  }

  return (
    <Page.Root aria-label={t("aria_job")} gutter="responsive" size="wide">
      {detail.isPending ? <PanelMessage>{t("loading")}</PanelMessage> : null}
      {detail.isError ? <PanelMessage tone="error">{errorMessage(detail.error, t("load_error"))}</PanelMessage> : null}
      {payload ? (
        <JobDetailView
          activeTab={activeTab}
          initialDiff={initialDiff}
          onSelectTab={selectTab}
          payload={payload}
          prefix={prefix}
          queryKey={queryKey}
          workflowsError={workflows.error}
          workflowsLoading={(activeTab === "workflows" || activeTab === "timeline") && workflows.isPending}
          workflowsQueryKey={workflowsQueryKey}
        />
      ) : null}
    </Page.Root>
  )
}

export function JobDetailView({
  payload,
  queryKey,
  workflowsQueryKey,
  workflowsLoading = false,
  workflowsError = null,
  activeTab,
  onSelectTab,
  prefix,
  initialDiff = null
}: {
  payload: JobDetailPayload
  queryKey: JobDetailQueryKey
  workflowsQueryKey?: JobWorkflowsQueryKey
  workflowsLoading?: boolean
  workflowsError?: Error | null
  activeTab: JobTab
  onSelectTab: (tab: JobTab) => void
  prefix: string
  initialDiff?: { base: string; head: string } | null
}) {
  const { t } = useT("jobs")
  const { t: tTours } = useT("tours")
  const location = useLocation()
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const [notice, setNotice] = useState<string | null>(payload.message || null)
  const [feedbackPanelOpen, setFeedbackPanelOpen] = useState(false)
  const [previewStopModal, setPreviewStopModal] = useState<{ onProceed: () => void } | null>(null)
  const command = useJobCommand(payload.job.id, queryKey, workflowsQueryKey, setNotice)
  const bugReportTrigger = useBugReportTrigger()
  const title = payload.job.issue_title || jobSourceLabel(payload, t)
  const workflowAnchor = location.hash.startsWith("#workflow-") ? location.hash.slice(1) : null
  const renderedWorkflowIds = payload.workflows.map((workflow) => workflow.id).join(",")
  const navigationToken = new URLSearchParams(location.search).get("job_nav")
  const [navigationContext, setNavigationContext] = useState<JobNavigationContext | null>(() => readJobNavigationContext(navigationToken))

  const previewRunning = payload.preview?.state === "running"

  function withPreviewStop(proceed: () => void) {
    if (previewRunning) {
      setPreviewStopModal({ onProceed: proceed })
    } else {
      proceed()
    }
  }

  const stopPreview = useMutation({
    mutationFn: () => stopPreviewRequest(payload.paths.app_preview_path),
    onSettled: () => {
      if (previewStopModal) {
        previewStopModal.onProceed()
        setPreviewStopModal(null)
      }
    }
  })

  const feedback = useMutation({
    mutationFn: (body: string) => submitJobFeedback(payload.job.id, body),
    onSuccess: () => {
      setFeedbackPanelOpen(false)
      setNotice(t("feedback_submitted"))
      scheduleJobDetailInvalidation(queryClient, queryKey)
      if (workflowsQueryKey) scheduleJobDetailInvalidation(queryClient, workflowsQueryKey)
    }
  })

  const requestChangesInCodingMode = useMutation({
    mutationFn: (body: string) => openJobInCodingMode(payload.paths.app_open_in_coding_mode_path, body),
    onSuccess: (result) => {
      setFeedbackPanelOpen(false)
      setNotice(result.message || t("open_in_coding_mode_feedback_submitted"))
      if (result.redirect_to) navigate(result.redirect_to)
      scheduleJobDetailInvalidation(queryClient, queryKey)
    }
  })

  const { run: tourRun, handleJoyrideCallback } = useTour("job_detail")
  const tourSteps = [
    {
      target: "[data-tour='job-timeline']",
      title: tTours("job_detail.timeline_title"),
      content: tTours("job_detail.timeline_content"),
      placement: "right" as const
    },
    {
      target: "[data-tour='job-approve']",
      title: tTours("job_detail.approve_title"),
      content: tTours("job_detail.approve_content"),
      placement: "bottom" as const
    },
    {
      target: "[data-tour='job-feedback']",
      title: tTours("job_detail.feedback_title"),
      content: tTours("job_detail.feedback_content"),
      placement: "bottom" as const
    },
    {
      target: "[data-tour='job-pr-link']",
      title: tTours("job_detail.pr_title"),
      content: tTours("job_detail.pr_content"),
      placement: "bottom" as const
    }
  ]

  useEffect(() => {
    setNotice(payload.message || null)
  }, [payload.job.id, payload.message])

  useEffect(() => {
    const context = readJobNavigationContext(navigationToken)
    if (context && navigationIndex(context, payload.job.id) >= 0) {
      setNavigationContext(context)
    } else {
      setNavigationContext(null)
    }
  }, [navigationToken, payload.job.id])

  useEffect(() => {
    if (!navigationContext) return

    const updated = withUpdatedNavigationItemState(navigationContext, payload.job.id, payload.job.summary_state)
    if (updated === navigationContext) return

    storeJobNavigationContext(updated)
    setNavigationContext(updated)
  }, [navigationContext, payload.job.id, payload.job.summary_state])

  useEffect(() => {
    const attachment = jobWorkflowContextBugReportAttachment(payload)
    if (!attachment) return undefined

    return bugReportTrigger.registerBugReportAttachments([attachment])
  }, [bugReportTrigger, payload])

  useEffect(() => {
    if (activeTab !== "workflows" || !workflowAnchor) return undefined

    const frame = window.requestAnimationFrame(() => {
      document.getElementById(workflowAnchor)?.scrollIntoView({ block: "start" })
    })

    return () => window.cancelAnimationFrame(frame)
  }, [activeTab, workflowAnchor, renderedWorkflowIds])

  const providerLabel = payload.job.agent_provider ? agentProviderLabel(payload, payload.job.agent_provider) : null

  return (
    <>
      <SyrusTour onEvent={(data) => handleJoyrideCallback(data)} run={tourRun} steps={tourSteps} />
      <Page.Header className="gap-3" layout="stacked">
        <PageHeading className="break-words" data-testid="job-header-title">
          <CopyableSlug slug={jobSlug(payload.job.id)} />
          <span className="px-2 text-gray-400 dark:text-gray-500">·</span>
          <PendingJobTitle pending={Boolean(payload.job.title_pending)} title={title} />
        </PageHeading>
        <div className="flex min-w-0 flex-wrap items-center justify-between gap-x-6 gap-y-3">
          <HeaderMetadataList>
            <JobStateBadge state={payload.job.summary_state} />
            <span className="min-w-0 break-words">
              <Link className="font-mono hover:underline" to={withRoutePrefix(payload.repository.repository_path, prefix)}>
                {payload.repository.slug}
              </Link>
            </span>
            {providerLabel ? (
              <span className="inline-flex items-center gap-1">
                <span title={providerFailoverTooltip(payload.job.provider_failover)}>{providerLabel}</span>
                <ProviderAvailabilityWarning availability={payload.job.provider_availability} />
              </span>
            ) : null}
            {payload.job.source_chat ? (
              <span className="inline-flex min-w-0 items-center gap-1">
                <SlugHoverCard id={payload.job.source_chat.chat_id} kind="chat">
                  <CopyableSlug className="text-xs" slug={`CHAT-${payload.job.source_chat.chat_id}`} />
                </SlugHoverCard>
                <Link className="min-w-0 break-words font-medium text-brand hover:underline" to={withRoutePrefix(payload.job.source_chat.path, prefix)}>
                  {payload.job.source_chat.chat_title || t("chat:new_title")}
                </Link>
              </span>
            ) : payload.origin_chat ? (
              <Link
                className="inline-flex min-w-0 items-center gap-1 font-medium text-brand hover:underline"
                to={withRoutePrefix(`/chats/${payload.origin_chat.chat_session_id}#message-${payload.origin_chat.message_id}`, prefix)}
              >
                <ChatBubbleIcon />
                <span>{t("view_in_chat")}</span>
              </Link>
            ) : payload.job.discussion_chat ? (
              <Link
                className="inline-flex min-w-0 items-center gap-1 font-medium text-brand hover:underline"
                to={withRoutePrefix(payload.job.discussion_chat.path, prefix)}
              >
                <ChatBubbleIcon />
                <span className="min-w-0 break-words">{payload.job.discussion_chat.chat_title || t("chat_about_this")}</span>
              </Link>
            ) : payload.actions.can_start_chat ? (
              <button
                className="inline-flex items-center gap-1 text-xs font-medium text-brand hover:underline disabled:cursor-not-allowed disabled:opacity-50"
                disabled={command.isPending}
                onClick={() => command.mutate({ method: "post", path: payload.paths.app_start_chat_path })}
                type="button"
              >
                <ChatBubbleIcon />
                <span>{t("chat_about_this")}</span>
              </button>
            ) : null}
          </HeaderMetadataList>
          <div className="flex min-w-0 shrink-0 flex-wrap items-center justify-start gap-3 sm:justify-end" data-testid="job-header-actions">
            <HeaderActions
              command={command}
              onApprove={() => withPreviewStop(() => command.mutate({ method: "post", path: payload.paths.app_approve_path }))}
              onToggleFeedbackPanel={() => withPreviewStop(() => setFeedbackPanelOpen((current) => !current))}
              payload={payload}
            />
            <JobNavigationControl context={navigationContext} currentJobId={payload.job.id} prefix={prefix} />
          </div>
        </div>
      </Page.Header>

      <NoticeToast message={notice} onDismiss={() => setNotice(null)} />
      {command.isError ? <PanelMessage tone="error">{errorMessage(command.error, t("command_error"))}</PanelMessage> : null}
      {command.dialog}
      {mainHealthBannerVisible(payload) ? (
        <Notice className="flex items-center gap-3" role="alert" tone="warning">
          <span>{payload.job.main_branch_repair ? t("main_branch_repair_active") : t("main_branch_health_waiting")}</span>
          {!payload.job.main_branch_repair ? (
            <Link
              className="shrink-0 rounded border border-amber-300 bg-white px-2 py-1 text-xs font-medium text-amber-800 hover:bg-amber-50 dark:border-amber-800 dark:bg-amber-950 dark:text-amber-200 dark:hover:bg-amber-900"
              to={withRoutePrefix(payload.repository.repository_path, prefix)}
            >
              {t("main_branch_health_view")}
            </Link>
          ) : null}
        </Notice>
      ) : null}
      {feedbackPanelOpen ? (
        <JobFeedbackPanel
          canGiveFeedback={canSubmitFeedbackDirectly(payload)}
          canOpenInCodingMode={payload.actions.can_open_in_coding_mode}
          codingModeBlockedReason={payload.actions.open_in_coding_mode_blocked_reason}
          codingModeError={requestChangesInCodingMode.error}
          feedbackError={feedback.error}
          isCodingModePending={requestChangesInCodingMode.isPending}
          isFeedbackPending={feedback.isPending}
          onCancel={() => setFeedbackPanelOpen(false)}
          onSubmitFeedback={(body) => withPreviewStop(() => feedback.mutate(body))}
          onSubmitToCodingMode={(body) => withPreviewStop(() => requestChangesInCodingMode.mutate(body))}
        />
      ) : null}
      {previewStopModal ? (
        <PreviewStopModal
          onKeepRunning={() => {
            previewStopModal.onProceed()
            setPreviewStopModal(null)
          }}
          onStop={() => stopPreview.mutate()}
        />
      ) : null}

      <Page.Nav>
        <TabNav
          active={activeTab}
          artifactsCount={(payload.typed_artifacts ?? []).length}
          attachmentsCount={(payload.attachments ?? []).length}
          investigation={payload.job.investigation}
          workflowsCount={payload.job.workflows_count}
          pluginTabs={payload.ui_tabs}
          onSelect={onSelectTab}
        />
      </Page.Nav>

      {activeTab === "summary" ? (
        payload.job.investigation ? (
          <ReportTab payload={payload} />
        ) : (
          <SummaryTab command={command} payload={payload} prefix={prefix} queryKey={queryKey} withPreviewStop={withPreviewStop} />
        )
      ) : null}
      {activeTab === "review" && !payload.job.investigation ? <ReviewWorkspace payload={payload} /> : null}
      {activeTab === "workflows" ? (
        <WorkflowsTab command={command} error={workflowsError} loading={workflowsLoading} payload={payload} prefix={prefix} />
      ) : null}
      {activeTab === "conversation" ? <AgentConversationTab jobId={payload.job.id} prUrl={payload.job.pr_url} /> : null}
      {activeTab === "timeline" ? (
        <TimelineTab error={workflowsError} jobId={String(payload.job.id)} loading={workflowsLoading} workflows={payload.workflows} />
      ) : null}
      {activeTab === "target_graph" ? <JobTargetGraphPanel jobId={payload.job.id} prefix={prefix} /> : null}
      {activeTab === "attachments" ? <AttachmentsTab payload={payload} queryKey={queryKey} onNotice={setNotice} /> : null}
      {activeTab === "artifacts" ? <ArtifactsTab artifacts={payload.typed_artifacts ?? []} /> : null}
      {activeTab === "source" ? (
        <SourceTab
          canReviewDiff={diffReviewFeedbackAllowed(payload.job.summary_state)}
          initialDiff={initialDiff}
          jobId={String(payload.job.id)}
          coverageInfo={payload.coverage ? { workflowId: payload.coverage.workflow_id, coverage: payload.coverage.coverage } : null}
        />
      ) : null}
      <PluginUiSlot panels={(payload.ui_tabs ?? []).filter((tab) => tab.key === activeTab)} props={{ job: payload.job }} />
    </>
  )
}

function HeaderMetadataList({ children }: { children: ReactNode }) {
  const items = Array.isArray(children) ? children.filter(Boolean) : [children].filter(Boolean)

  return (
    <div className="flex min-w-0 flex-1 flex-wrap items-center gap-x-2 gap-y-1 text-sm text-gray-600 dark:text-gray-300" data-testid="job-header-metadata">
      {items.map((item, index) => (
        <span key={index} className="inline-flex min-w-0 items-center gap-2">
          {index > 0 ? <span className="shrink-0 text-gray-300 dark:text-gray-600">·</span> : null}
          {item}
        </span>
      ))}
    </div>
  )
}

function JobNavigationControl({ context, currentJobId, prefix }: { context: JobNavigationContext | null; currentJobId: number; prefix: string }) {
  const { t } = useT("jobs")
  const location = useLocation()
  const navigate = useNavigate()
  const activeIndex = useMemo(() => (context ? navigationIndex(context, currentJobId) : -1), [context, currentJobId])
  const previous = context && activeIndex > 0 ? context.items[activeIndex - 1] : null
  const next = context && activeIndex >= 0 && activeIndex < context.items.length - 1 ? context.items[activeIndex + 1] : null
  const current = context && activeIndex >= 0 ? context.items[activeIndex] : null
  const [jumpOpen, setJumpOpen] = useState(false)
  const wrapperRef = useRef<HTMLDivElement | null>(null)
  const currentOptionRef = useRef<HTMLButtonElement | null>(null)

  useEffect(() => {
    if (!context || activeIndex < 0) return undefined
    const activeContext = context

    function onKeyDown(event: KeyboardEvent) {
      if (event.defaultPrevented || event.altKey || event.ctrlKey || event.metaKey || event.shiftKey) return
      if (navigationShortcutBlocked(event.target)) return

      const key = event.key.toLowerCase()
      if (key === "n" && next) {
        event.preventDefault()
        navigate(jobNavigationHref(next.path, prefix, activeContext.token, location.search, location.pathname))
      } else if (key === "p" && previous) {
        event.preventDefault()
        navigate(jobNavigationHref(previous.path, prefix, activeContext.token, location.search, location.pathname))
      }
    }

    window.addEventListener("keydown", onKeyDown)
    return () => window.removeEventListener("keydown", onKeyDown)
  }, [activeIndex, context, location.search, navigate, next, prefix, previous])

  useEffect(() => {
    if (!jumpOpen) return undefined

    function onPointerDown(event: PointerEvent) {
      if (wrapperRef.current?.contains(event.target as Node)) return
      setJumpOpen(false)
    }

    function onKeyDown(event: KeyboardEvent) {
      if (event.key === "Escape") setJumpOpen(false)
    }

    document.addEventListener("pointerdown", onPointerDown)
    document.addEventListener("keydown", onKeyDown)
    return () => {
      document.removeEventListener("pointerdown", onPointerDown)
      document.removeEventListener("keydown", onKeyDown)
    }
  }, [jumpOpen])

  useEffect(() => {
    if (!jumpOpen) return

    window.requestAnimationFrame(() => {
      currentOptionRef.current?.scrollIntoView({ block: "center" })
    })
  }, [jumpOpen])

  if (!context || activeIndex < 0 || !current) return null
  const activeContext = context

  function navigateTo(path: string) {
    setJumpOpen(false)
    navigate(jobNavigationHref(path, prefix, activeContext.token, location.search, location.pathname))
  }

  return (
    <div
      className="relative hidden shrink-0 items-center gap-1 rounded border border-gray-200 bg-white p-1 text-xs text-gray-600 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-300 md:inline-flex"
      aria-label={t("navigation_label")}
      ref={wrapperRef}
    >
      <button
        aria-label={t("navigation_previous")}
        className="flex h-7 w-7 items-center justify-center rounded text-gray-500 hover:bg-gray-100 hover:text-gray-900 disabled:cursor-not-allowed disabled:opacity-40 dark:text-gray-400 dark:hover:bg-gray-800 dark:hover:text-gray-100"
        disabled={!previous}
        onClick={() => (previous ? navigateTo(previous.path) : undefined)}
        title={t("navigation_previous_shortcut")}
        type="button"
      >
        <span aria-hidden="true">‹</span>
      </button>
      <button
        aria-controls="job-navigation-jump-list"
        aria-expanded={jumpOpen}
        aria-haspopup="listbox"
        aria-label={t("navigation_jump")}
        className="flex h-7 min-w-0 max-w-[7.5rem] items-center gap-1 rounded px-2 text-left font-mono text-xs font-medium text-gray-700 hover:bg-gray-100 focus:outline-none focus:ring-2 focus:ring-brand dark:text-gray-200 dark:hover:bg-gray-800"
        onClick={() => setJumpOpen((open) => !open)}
        title={context.label}
        type="button"
      >
        <span className="truncate">{current.slug}</span>
        <span aria-hidden="true" className="text-gray-400 dark:text-gray-500">
          ▾
        </span>
      </button>
      {jumpOpen ? (
        <div
          className="absolute right-0 top-full z-30 mt-1 max-h-80 w-96 max-w-[min(24rem,calc(100vw-2rem))] overflow-y-auto rounded-md border border-gray-200 bg-white py-1 text-sm shadow-lg dark:border-gray-700 dark:bg-gray-950"
          id="job-navigation-jump-list"
          role="listbox"
        >
          {context.items.map((item, index) => (
            <button
              aria-label={t("navigation_jump_option", { position: index + 1, slug: item.slug, title: item.title })}
              aria-selected={item.id === currentJobId}
              className={`block w-full px-3 py-2 text-left hover:bg-gray-50 focus:bg-gray-50 focus:outline-none dark:hover:bg-gray-900 dark:focus:bg-gray-900 ${item.id === currentJobId ? "bg-brand/10 text-gray-950 dark:text-gray-50" : "text-gray-700 dark:text-gray-200"}`}
              key={item.id}
              onClick={() => navigateTo(item.path)}
              ref={item.id === currentJobId ? currentOptionRef : undefined}
              role="option"
              type="button"
            >
              <span className="flex flex-col gap-1">
                <span className="min-w-0 break-words leading-snug">{item.title}</span>
                <MetadataLine className="flex flex-wrap items-center gap-x-1.5 gap-y-1 text-xs text-gray-500 dark:text-gray-400">
                  {item.state ? <StatusPill state={item.state} wrap /> : null}
                  <span className="font-mono font-semibold text-gray-500 dark:text-gray-400">{item.slug}</span>
                  {item.ownerBadge ? <OwnerBadge badge={item.ownerBadge} /> : null}
                  {item.updatedAt ? <RelativeTimestamp value={item.updatedAt} /> : null}
                </MetadataLine>
              </span>
            </button>
          ))}
        </div>
      ) : null}
      <span className="whitespace-nowrap px-1 text-gray-400 dark:text-gray-500">
        {t("navigation_position", { current: activeIndex + 1, total: context.items.length })}
      </span>
      <button
        aria-label={t("navigation_next")}
        className="flex h-7 w-7 items-center justify-center rounded text-gray-500 hover:bg-gray-100 hover:text-gray-900 disabled:cursor-not-allowed disabled:opacity-40 dark:text-gray-400 dark:hover:bg-gray-800 dark:hover:text-gray-100"
        disabled={!next}
        onClick={() => (next ? navigateTo(next.path) : undefined)}
        title={t("navigation_next_shortcut")}
        type="button"
      >
        <span aria-hidden="true">›</span>
      </button>
    </div>
  )
}

function navigationShortcutBlocked(target: EventTarget | null) {
  if (document.querySelector("[role='dialog'], [aria-modal='true']")) return true
  if (!(target instanceof Element)) return false
  if (target.closest("input, textarea, select, [contenteditable='true'], [role='textbox'], [role='combobox'], [data-navigation-shortcuts='ignore']"))
    return true

  return false
}

function TabNav({
  active,
  workflowsCount,
  attachmentsCount,
  artifactsCount,
  investigation = false,
  pluginTabs,
  onSelect
}: {
  active: JobTab
  workflowsCount: number
  attachmentsCount: number
  artifactsCount: number
  investigation?: boolean
  pluginTabs?: UiSlotPanel[]
  onSelect: (tab: JobTab) => void
}) {
  const { t } = useT("jobs")
  // Investigation Jobs never reach pr_open, so there is no PR to review --
  // the "review" tab (PR diff + review comments) is hidden entirely rather
  // than rendered empty. The "summary" tab id is kept (its content swaps to
  // the Report view in JobDetailView), just relabeled as the Job's primary
  // deliverable.
  const tabs: Array<{ id: JobTab; label: string }> = [
    { id: "summary", label: investigation ? t("tab_report") : t("tab_summary") },
    ...(investigation ? [] : [{ id: "review" as JobTab, label: t("tab_review") }]),
    { id: "workflows", label: t("tab_workflows", { count: workflowsCount }) },
    { id: "conversation", label: t("tab_conversation") },
    { id: "timeline", label: t("tab_timeline") },
    { id: "target_graph", label: "Target Graph" },
    { id: "attachments", label: t("tab_attachments", { count: attachmentsCount }) },
    { id: "artifacts", label: t("tab_artifacts", { count: artifactsCount }) },
    { id: "source", label: t("tab_source") }
  ]

  // Plugin-contributed tabs (test_insights' Tests tab, for one) append after
  // the built-ins; a plugin decides for itself whether a Job warrants one.
  for (const pluginTab of pluginTabs ?? []) {
    if (!pluginTab.key) continue
    tabs.push({ id: pluginTab.key, label: pluginTab.label_key ? t(pluginTab.label_key) : (pluginTab.label ?? pluginTab.key) })
  }

  return (
    <UnderlineTabs
      activeKey={active}
      activeClassName="border-brand text-brand"
      ariaLabel="Job sections"
      className="scroll-fade-x flex overflow-x-auto border-b border-gray-200 dark:border-gray-700"
      inactiveClassName="border-transparent text-gray-500 hover:text-gray-800 dark:text-gray-400 dark:hover:text-gray-200"
      itemClassName="px-4 py-3 text-sm"
      items={tabs.map((tab) => ({ key: tab.id, label: tab.label }))}
      onSelect={onSelect}
    />
  )
}

function SummaryTab({
  payload,
  command,
  prefix,
  queryKey,
  withPreviewStop
}: {
  payload: JobDetailPayload
  command: ReturnType<typeof useJobCommand>
  prefix: string
  queryKey: JobDetailQueryKey
  withPreviewStop: (proceed: () => void) => void
}) {
  const { t } = useT("jobs")
  const coverageInfo = payload.coverage
  // Defaulted like the other two read sites: the payload type declares this
  // required, but a payload without it crashes the whole Summary tab through
  // the route error boundary rather than just hiding one panel.
  const typedArtifacts = payload.typed_artifacts ?? []
  const showUnsatisfiedDependencies = payload.job.state !== "landing" && payload.unsatisfied_dependencies.length > 0
  return (
    <div className="space-y-4">
      <NeedsAttentionBanner job={payload.job} />
      <TriageDecisionBanner job={payload.job} />
      <JobSummaryNotices command={command} payload={payload} prefix={prefix} showUnsatisfiedDependencies={showUnsatisfiedDependencies} />

      <div className="grid grid-cols-1 gap-4 lg:grid-cols-[62%_38%]">
        <div className="min-w-0 space-y-4">
          <Section.Root className="min-w-0 overflow-x-auto">
            <SectionHeading>{t("section_issue")}</SectionHeading>
            {payload.job.issue_body ? (
              <Markdown className="chat-prose mt-2 text-sm text-gray-700 dark:text-gray-300" text={payload.job.issue_body} />
            ) : (
              <p className="mt-2 text-sm text-gray-400 dark:text-gray-500">{t("no_issue_body")}</p>
            )}
          </Section.Root>
          <Section.Root className="min-w-0 overflow-x-auto">
            <SectionHeading>{t("section_agent_summary")}</SectionHeading>
            {payload.summary ? (
              <Markdown className="chat-prose mt-2 text-sm text-gray-700 dark:text-gray-300" text={payload.summary.text} />
            ) : (
              <p className="mt-2 text-sm text-gray-400 dark:text-gray-500">{t("no_summary")}</p>
            )}
          </Section.Root>

          <TestPlanPanel testPlan={payload.test_plan} />

          {typedArtifacts.length > 0 ? <TypedArtifactPanel artifacts={typedArtifacts} /> : null}

          {coverageInfo ? <CoverageCard coverage={coverageInfo.coverage} /> : null}

          <PluginUiSlot panels={payload.ui_panels} props={{ job: payload.job }} />

          <PendingFeedbackPanel jobId={payload.job.id} comments={payload.pending_feedback} queryKey={queryKey} />

          <FeedbackHistoryPanel entries={payload.feedback_history} prefix={prefix} />

          <TimelinePanel canView={payload.actions.can_view_timeline} jobId={payload.job.id} prefix={prefix} runsCount={payload.job.runs_count} />
          <AttachmentPreview attachments={payload.attachments} />
        </div>

        <div className="min-w-0 space-y-4">
          <PreviewPanel
            canStart={payload.actions.can_start_preview}
            initialPreview={payload.preview}
            initialPreviewProjects={payload.preview_projects}
            previewUnavailableReason={payload.preview_unavailable_reason}
            queryKeyPrefix="job"
            entityId={payload.job.id}
            previewLogsPath={payload.paths.app_preview_logs_path}
            previewPath={payload.paths.app_preview_path}
            queryKey={queryKey}
            repositoryId={payload.repository.id}
            canDeploy={payload.actions.can_deploy}
            initialDeploy={payload.deploy}
            deployPath={payload.paths.app_deploy_path}
          />

          <Section.Root className="min-w-0 overflow-x-auto text-sm" data-tour="job-pr-link">
            <SectionHeading>{t("section_details")}</SectionHeading>
            {payload.deployment_stages?.length ? <DeploymentStagePipeline stages={payload.deployment_stages} /> : null}
            <div className="mt-3 grid grid-cols-1 gap-x-4 gap-y-3 sm:grid-cols-2">
              <KeyValue label={t("detail_state")}>
                <StatusPill state={payload.job.summary_state} />
              </KeyValue>
              <KeyValue label={t("detail_work_claim")}>
                <JobOwnerLabel command={command} payload={payload} prefix={prefix} />
              </KeyValue>
              <KeyValue label={t("detail_source")}>
                <JobSourceLink payload={payload} prefix={prefix} />
              </KeyValue>
              {!payload.job.created_by_current_user ? (
                <KeyValue label={t("detail_creator")}>{payload.job.creator_user.display_name || payload.job.creator_user.email_address}</KeyValue>
              ) : null}
              <KeyValue label={t("detail_priority")}>
                <PrioritySelector currentPriority={payload.job.priority} priorityPath={payload.paths.app_priority_path} queryKey={queryKey} />
              </KeyValue>
              <KeyValue label={t("detail_provider")}>
                <JobProviderSelector
                  payload={payload}
                  providerPath={payload.paths.app_provider_setting_path || `/api/v1/app/jobs/${payload.job.id}/provider_setting`}
                  queryKey={queryKey}
                />
              </KeyValue>
              <KeyValue label={t("detail_validity")}>
                <span className="capitalize">{payload.job.validity}</span>
              </KeyValue>
              {payload.job.invalidation_evidence?.length ? (
                <KeyValue label={t("detail_invalidation_evidence")}>
                  <InvalidationEvidenceList urls={payload.job.invalidation_evidence} />
                </KeyValue>
              ) : null}
              {payload.epic ? (
                <KeyValue label={t("detail_epic")}>
                  <EpicSummaryLink epic={payload.epic} prefix={prefix} />
                </KeyValue>
              ) : null}
              {payload.job.branch_name ? (
                <KeyValue label={t("detail_branch")}>
                  <code className="break-all">{payload.job.branch_name}</code>
                </KeyValue>
              ) : null}
              <KeyValue label={t("detail_stack_base")}>
                <StackBaseForm command={command} payload={payload} />
              </KeyValue>
              {payload.job.pr_number || payload.job.external_pr_number ? (
                <KeyValue label={t("detail_pull_request")}>
                  <PullRequestSummary payload={payload} />
                </KeyValue>
              ) : null}
              {!payload.job.pr_number && !payload.job.external_pr_number && payload.job.no_pr_reason ? (
                <KeyValue label={t("detail_pull_request")}>
                  <span className="text-gray-600 dark:text-gray-300">{payload.job.no_pr_reason.message || t("no_pr_opened")}</span>
                </KeyValue>
              ) : null}
              <KeyValue label={t("detail_cost")}>
                {payload.job.total_cost_usd == null ? "-" : <JobCostLink prefix={prefix} value={payload.job.total_cost_usd} />}{" "}
                <span className="text-xs text-gray-400 dark:text-gray-500">
                  ({payload.job.billed_runs_count} {t("detail_billed")})
                </span>
              </KeyValue>
              <KeyValue label={t("detail_started")}>
                <RelativeTimestamp value={payload.job.started_at} />
              </KeyValue>
              {payload.job.finished_at ? (
                <KeyValue label={t("detail_closed")}>
                  <RelativeTimestamp value={payload.job.finished_at} /> ({payload.job.closure_reason || "unspecified"})
                </KeyValue>
              ) : null}
              {payload.job.closure_reason === "emergency_landed" ? (
                <KeyValue label={t("detail_emergency_land")}>
                  <EmergencyLandAudit job={payload.job} />
                </KeyValue>
              ) : null}
              {payload.job.runaway_protection ? (
                <KeyValue label={t("detail_runaway_protection")}>
                  <span className="text-amber-700 dark:text-amber-400">{payload.job.runaway_protection}</span> — {t("detail_runaway_protection_hint")}
                </KeyValue>
              ) : null}
              {payload.job.landing_blocker_override_requested_at ? (
                <KeyValue label={t("detail_landing_blocker_override")}>
                  {t("landing_blocker_override_note", {
                    user:
                      payload.job.landing_blocker_override_requested_by?.display_name ?? payload.job.landing_blocker_override_requested_by?.email_address ?? "?"
                  })}{" "}
                  <RelativeTimestamp value={payload.job.landing_blocker_override_requested_at} />
                </KeyValue>
              ) : null}
            </div>
            <TagsPanel canManageTags={payload.actions.can_manage_tags} embedded command={command} payload={payload} />
          </Section.Root>

          <ApprovalStatusPanel payload={payload} prefix={prefix} />
          {deliveryPanelRelevant(payload) ? <DeliveryPanel payload={payload} /> : null}
          <DependenciesPanel command={command} payload={payload} />
        </div>
      </div>
    </div>
  )
}

const JOB_PRIORITIES = ["urgent", "high", "medium", "low"] as const

function JobCostLink({ prefix, value }: { prefix: string; value: number }) {
  return (
    <Link className="text-current underline-offset-2 hover:underline focus:underline" to={withRoutePrefix("/insights/spending", prefix)}>
      {formatCurrency(value)}
    </Link>
  )
}

function EmergencyLandAudit({ job }: { job: JobDetailPayload["job"] }) {
  const user = job.emergency_landed_by_user
  const userLabel = user?.display_name || user?.email_address || "Unknown user"
  const tier = job.emergency_landed_by_membership_tier

  return (
    <span className="inline-flex flex-col gap-1 text-sm">
      <span>{job.emergency_landed_at ? <RelativeTimestamp value={job.emergency_landed_at} /> : "Time not recorded"}</span>
      <span className="text-xs text-warning-text">
        Confirmed by {userLabel}
        {tier ? ` (${tier})` : ""}
      </span>
    </span>
  )
}

function PrioritySelector({ currentPriority, priorityPath, queryKey }: { currentPriority: string; priorityPath: string; queryKey: JobDetailQueryKey }) {
  const { t } = useT("jobs")
  const queryClient = useQueryClient()
  const [showConfirm, setShowConfirm] = useState(false)
  const [pendingPriority, setPendingPriority] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)

  const mutation = useMutation({
    mutationFn: (priority: string) => updateJobPriority(priorityPath, priority),
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey })
      void queryClient.invalidateQueries({ queryKey: ["jobs"], exact: true })
      setError(null)
    },
    onError: () => setError(t("priority_update_error"))
  })

  function handleChange(value: string) {
    if (value === "urgent") {
      setPendingPriority("urgent")
      setShowConfirm(true)
    } else {
      mutation.mutate(value)
    }
  }

  function handleConfirm() {
    if (pendingPriority) mutation.mutate(pendingPriority)
    setShowConfirm(false)
    setPendingPriority(null)
  }

  function handleCancel() {
    setShowConfirm(false)
    setPendingPriority(null)
  }

  const labels: Record<string, string> = {
    urgent: t("priority_urgent"),
    high: t("priority_high"),
    medium: t("priority_medium"),
    low: t("priority_low")
  }

  return (
    <span className="inline-flex flex-col gap-1">
      <Select
        aria-label={t("detail_priority")}
        className="py-0.5 pl-1.5 pr-6 text-xs"
        disabled={mutation.isPending}
        fullWidth={false}
        onChange={(e) => handleChange(e.target.value)}
        value={currentPriority}
      >
        {JOB_PRIORITIES.map((p) => (
          <option key={p} value={p}>
            {labels[p]}
          </option>
        ))}
      </Select>
      {error ? (
        <span className="text-xs text-red-600 dark:text-red-400" role="alert">
          {error}
        </span>
      ) : null}
      {showConfirm ? <UrgentConfirmDialog onCancel={handleCancel} onConfirm={handleConfirm} /> : null}
    </span>
  )
}

function JobProviderSelector({ payload, providerPath, queryKey }: { payload: JobDetailPayload; providerPath: string; queryKey: JobDetailQueryKey }) {
  const { t } = useT("jobs")
  const queryClient = useQueryClient()
  const [error, setError] = useState<string | null>(null)
  const currentSetting = payload.job.job_provider_setting || "default"
  const [draft, setDraft] = useState({
    jobProviderSetting: currentSetting,
    model: payload.job.model || "",
    effortLevel: payload.job.effort_level || ""
  })

  useEffect(() => {
    setDraft({
      jobProviderSetting: currentSetting,
      model: payload.job.model || "",
      effortLevel: payload.job.effort_level || ""
    })
  }, [currentSetting, payload.job.model, payload.job.effort_level])

  const mutation = useMutation({
    mutationFn: () => updateJobProviderSetting(providerPath, draft),
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey })
      void queryClient.invalidateQueries({ queryKey: ["jobs"], exact: true })
      setError(null)
    },
    onError: () => setError(t("provider_setting_update_error"))
  })
  const options = payload.job.job_provider_setting_options || [
    { value: "default" as const, label: t("provider_setting_default"), configured: true },
    { value: "claude" as const, label: "Claude Code", configured: true },
    { value: "codex" as const, label: "Codex", configured: true }
  ]
  const selectedOption = options.find((option) => option.value === draft.jobProviderSetting)
  const effortOptions = payload.job.provider_routing_options?.effort_levels || [
    { value: "none", label: t("provider_effort_level_none") },
    { value: "low", label: t("provider_effort_level_low") },
    { value: "medium", label: t("provider_effort_level_medium") },
    { value: "high", label: t("provider_effort_level_high") }
  ]

  return (
    <span className="inline-flex max-w-full flex-col gap-1">
      <Select
        aria-describedby={`job-${payload.job.id}-provider-help`}
        aria-label={t("detail_provider")}
        className="max-w-full py-0.5 pl-1.5 pr-6 text-xs"
        disabled={mutation.isPending}
        fullWidth={false}
        onChange={(event) => setDraft({ ...draft, jobProviderSetting: event.target.value, model: "" })}
        value={draft.jobProviderSetting}
      >
        {options.map((option) => (
          <option disabled={!option.configured} key={option.value} value={option.value}>
            {option.value === "default" ? t("provider_setting_default") : option.label}
          </option>
        ))}
      </Select>
      {draft.jobProviderSetting !== "default" ? (
        <span className="grid gap-1 sm:grid-cols-2">
          <Select
            aria-label={t("provider_model_label")}
            className="max-w-full py-0.5 pl-1.5 pr-6 text-xs"
            disabled={mutation.isPending}
            fullWidth={false}
            onChange={(event) => setDraft({ ...draft, model: event.target.value })}
            value={draft.model}
          >
            <option value="">{t("provider_default_model")}</option>
            {(selectedOption?.models || []).map((model) => (
              <option key={model.id} value={model.id}>
                {model.label}
              </option>
            ))}
          </Select>
          <Select
            aria-label={t("provider_effort_label")}
            className="max-w-full py-0.5 pl-1.5 pr-6 text-xs"
            disabled={mutation.isPending}
            fullWidth={false}
            onChange={(event) => setDraft({ ...draft, effortLevel: event.target.value })}
            value={draft.effortLevel}
          >
            <option value="">{t("provider_default_effort")}</option>
            {effortOptions.map((effort) => (
              <option key={effort.value} value={effort.value}>
                {t(`provider_effort_level_${effort.value}`, { defaultValue: effort.label })}
              </option>
            ))}
          </Select>
          <Button className="sm:col-span-2" disabled={mutation.isPending} onClick={() => mutation.mutate()} size="sm" variant="secondary">
            {t("provider_override_save")}
          </Button>
        </span>
      ) : (
        <Button disabled={mutation.isPending || currentSetting === "default"} onClick={() => mutation.mutate()} size="sm" variant="secondary">
          {t("provider_override_default")}
        </Button>
      )}
      <span className="text-xs text-gray-500 dark:text-gray-400" id={`job-${payload.job.id}-provider-help`}>
        {t("provider_setting_help", { provider: agentProviderLabel(payload, payload.job.agent_provider || "") })}
      </span>
      {error ? (
        <span className="text-xs text-red-600 dark:text-red-400" role="alert">
          {error}
        </span>
      ) : null}
    </span>
  )
}

function agentProviderLabel(payload: JobDetailPayload, provider: string) {
  if (!provider) return "default"

  return payload.job.agent_provider === provider
    ? payload.job.agent_provider_label || provider
    : payload.job.job_provider_setting_options?.find((option) => option.value === provider)?.label || provider
}

function UrgentConfirmDialog({ onConfirm, onCancel }: { onConfirm: () => void; onCancel: () => void }) {
  const { t } = useT("jobs")

  useEffect(() => {
    function onKeyDown(e: KeyboardEvent) {
      if (e.key === "Escape") onCancel()
    }
    document.addEventListener("keydown", onKeyDown)
    return () => document.removeEventListener("keydown", onKeyDown)
  }, [onCancel])

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4" onClick={onCancel}>
      <section
        aria-labelledby="urgent-confirm-title"
        aria-modal="true"
        className="w-full max-w-md rounded-lg bg-white shadow-xl dark:bg-gray-900"
        role="dialog"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="space-y-4 p-5">
          <SectionHeading id="urgent-confirm-title">{t("priority_urgent_confirm_title")}</SectionHeading>
          <p className="text-sm text-gray-700 dark:text-gray-300">{t("priority_urgent_confirm_body_1")}</p>
          <p className="text-sm text-gray-700 dark:text-gray-300">{t("priority_urgent_confirm_body_2")}</p>
          <div className="flex justify-end gap-3">
            <Button onClick={onCancel} variant="secondary">
              {t("priority_cancel")}
            </Button>
            <Button onClick={onConfirm} variant="danger">
              {t("priority_urgent_confirm_button")}
            </Button>
          </div>
        </div>
      </section>
    </div>
  )
}

export function TestPlanPanel({ testPlan }: { testPlan: JobTestPlan | null }) {
  const { t } = useT("jobs")
  if (!testPlan || (testPlan.steps.length === 0 && !testPlan.notes)) return null

  return (
    <section className="min-w-0 overflow-x-auto rounded border border-gray-200 bg-white p-4 dark:border-gray-700 dark:bg-gray-900">
      <SectionHeading>{t("section_test_plan")}</SectionHeading>
      <ol className="mt-2 min-w-0 max-w-full list-decimal space-y-1 pl-5 text-sm text-gray-700 dark:text-gray-300">
        {testPlan.steps.map((step, index) => (
          <li className="min-w-0 break-words [overflow-wrap:anywhere]" key={`${index}-${step}`}>
            {step}
          </li>
        ))}
      </ol>
      {testPlan.notes ? <Markdown className="chat-prose mt-3 text-sm text-gray-700 dark:text-gray-300" text={testPlan.notes} /> : null}
    </section>
  )
}

function PendingFeedbackPanel({ jobId, comments = [], queryKey }: { jobId: number; comments?: PendingFeedbackComment[]; queryKey: JobDetailQueryKey }) {
  const { t } = useT("jobs")
  const queryClient = useQueryClient()
  const [replaceId, setReplaceId] = useState<number | null>(null)
  const [replaceBody, setReplaceBody] = useState("")
  const [notice, setNotice] = useState<string | null>(null)

  const apply = useMutation({
    mutationFn: (commentId: number) => applyPendingFeedback(jobId, commentId),
    onSuccess: (data) => {
      setNotice(data.message)
      void queryClient.invalidateQueries({ queryKey })
    }
  })

  const ignore = useMutation({
    mutationFn: (commentId: number) => ignorePendingFeedback(jobId, commentId),
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey })
    }
  })

  const replace = useMutation({
    mutationFn: ({ commentId, body }: { commentId: number; body: string }) => replacePendingFeedback(jobId, commentId, body),
    onSuccess: (data) => {
      setReplaceId(null)
      setReplaceBody("")
      setNotice(data.message)
      void queryClient.invalidateQueries({ queryKey })
    }
  })

  const retry = useMutation({
    mutationFn: (commentId: number) => retryPendingFeedback(jobId, commentId),
    onSuccess: (data) => {
      setNotice(data.message)
      void queryClient.invalidateQueries({ queryKey })
    }
  })

  if (comments.length === 0) return null

  const isPending = apply.isPending || ignore.isPending || replace.isPending || retry.isPending

  return (
    <section className="rounded border border-amber-200 bg-amber-50 p-4 dark:border-amber-800/60 dark:bg-amber-950/30">
      <h2 className="text-sm font-semibold text-amber-900 dark:text-amber-200">{t("pending_feedback_title")}</h2>
      <p className="mt-1 text-xs text-amber-700 dark:text-amber-400">{t("pending_feedback_description")}</p>
      {notice ? (
        <div className="mt-2 flex items-center justify-between gap-2 rounded bg-amber-100 px-3 py-2 text-xs text-amber-800 dark:bg-amber-900/40 dark:text-amber-300">
          <span>{notice}</span>
          <button className="ml-2 hover:underline" onClick={() => setNotice(null)} type="button">
            {t("dismiss")}
          </button>
        </div>
      ) : null}
      {apply.isError || ignore.isError || replace.isError || retry.isError ? (
        <p className="mt-2 text-xs text-red-600 dark:text-red-400">
          {apply.error instanceof Error
            ? apply.error.message
            : ignore.error instanceof Error
              ? ignore.error.message
              : replace.error instanceof Error
                ? replace.error.message
                : retry.error instanceof Error
                  ? retry.error.message
                  : "Action failed."}
        </p>
      ) : null}
      <div className="mt-3 space-y-3">
        {comments.map((comment) => (
          <div className="rounded border border-amber-200 bg-white p-3 dark:border-amber-800/40 dark:bg-gray-900" key={comment.id}>
            <div className="flex flex-wrap items-center gap-2 text-xs text-amber-700 dark:text-amber-400">
              {comment.github_handle ? <span className="font-medium">@{comment.github_handle}</span> : null}
              <span className="capitalize">{comment.attributed_to}</span>
              <span>·</span>
              <span className="capitalize">{comment.pr_type} PR</span>
              {comment.comment_created_at ? (
                <span>
                  · <RelativeTimestamp value={comment.comment_created_at} />
                </span>
              ) : null}
            </div>
            <p className="mt-2 whitespace-pre-wrap break-words text-sm text-gray-700 dark:text-gray-300">{comment.body}</p>
            {comment.handling_state === "failed" ? (
              <p className="mt-2 text-xs font-medium text-red-700 dark:text-red-300">
                {t("pending_feedback_last_failed", { reason: comment.handling_failure_reason || t("pending_feedback_failure_unknown") })}
              </p>
            ) : null}
            {replaceId === comment.id ? (
              <div className="mt-3 space-y-2">
                <textarea
                  aria-label={t("replacement_feedback_aria")}
                  className="block w-full rounded border border-gray-300 bg-white px-3 py-2 text-sm focus:outline-brand dark:border-gray-600 dark:bg-gray-800 dark:text-gray-200"
                  onChange={(e) => setReplaceBody(e.target.value)}
                  placeholder={t("replacement_feedback_placeholder")}
                  rows={3}
                  value={replaceBody}
                />
                <div className="flex gap-2">
                  <Button disabled={isPending || !replaceBody.trim()} onClick={() => replace.mutate({ commentId: comment.id, body: replaceBody })} size="sm">
                    Submit replacement
                  </Button>
                  <button
                    className="text-xs text-gray-500 hover:underline dark:text-gray-400"
                    onClick={() => {
                      setReplaceId(null)
                      setReplaceBody("")
                    }}
                    type="button"
                  >
                    Cancel
                  </button>
                </div>
              </div>
            ) : (
              <div className="mt-3 flex flex-wrap gap-2">
                {comment.retryable ? (
                  <Button disabled={isPending} onClick={() => retry.mutate(comment.id)} size="sm">
                    {t("pending_feedback_retry")}
                  </Button>
                ) : (
                  <>
                    <Button disabled={isPending} onClick={() => apply.mutate(comment.id)} size="sm">
                      Apply
                    </Button>
                    <Button
                      disabled={isPending}
                      onClick={() => {
                        setReplaceId(comment.id)
                        setReplaceBody("")
                      }}
                      size="sm"
                      variant="secondary"
                    >
                      Replace
                    </Button>
                  </>
                )}
                <button
                  className="text-xs text-gray-500 hover:underline disabled:cursor-not-allowed disabled:opacity-50 dark:text-gray-400"
                  disabled={isPending}
                  onClick={() => ignore.mutate(comment.id)}
                  type="button"
                >
                  Ignore
                </button>
              </div>
            )}
          </div>
        ))}
      </div>
    </section>
  )
}

export function FeedbackHistoryPanel({ entries, prefix }: { entries: JobDetailPayload["feedback_history"]; prefix: string }) {
  const { t } = useT("jobs")
  const feedbackEntries = [...(entries || [])].sort((left, right) => feedbackCreatedAtTime(right) - feedbackCreatedAtTime(left))

  if (feedbackEntries.length === 0) return null

  return (
    <section className="rounded border border-gray-200 bg-white p-4 dark:border-gray-700 dark:bg-gray-900">
      <SectionHeading>{t("section_feedback_history")}</SectionHeading>
      <div className="mt-3">
        {feedbackEntries.map((entry, index) => {
          const chatFeedback = entry.body
          return (
            <div className="mt-3 border-t border-gray-100 pt-3 first:mt-0 first:border-t-0 first:pt-0 dark:border-gray-800" key={entry.workflow_id ?? index}>
              <div className="flex flex-wrap items-center justify-between gap-2">
                <div className="flex flex-wrap items-center gap-2">
                  <span className="text-sm font-medium text-gray-900 dark:text-gray-100">{feedbackTriggerLabel(entry.kind, t)}</span>
                  <StatusPill state={entry.state} />
                </div>
                <div className="flex flex-wrap items-center gap-2 text-xs text-gray-500 dark:text-gray-400">
                  <span>
                    <RelativeTimestamp value={entry.created_at} />
                  </span>
                  {entry.workflow_path ? (
                    <Link className="text-brand hover:underline" to={withRoutePrefix(entry.workflow_path, prefix)}>
                      {entry.workflow_slug || (entry.workflow_id ? workflowSlug(entry.workflow_id) : t("workflow"))}
                    </Link>
                  ) : null}
                </div>
              </div>
              {entry.kind === "chat_feedback" ? (
                <>
                  <FeedbackSourceBadge source={entry.feedback_source} />
                  <div className="mt-2 text-sm text-gray-700 dark:text-gray-300 [&_code]:rounded [&_code]:bg-gray-100 [&_code]:px-0.5 [&_code]:font-mono dark:[&_code]:bg-gray-800 [&_h1]:font-semibold [&_h2]:font-semibold [&_h3]:font-semibold [&_pre]:rounded [&_pre]:bg-gray-100 [&_pre]:p-1.5 [&_pre]:font-mono dark:[&_pre]:bg-gray-800 [&_pre_code]:bg-transparent [&_pre_code]:px-0">
                    <Markdown text={typeof chatFeedback === "string" ? chatFeedback : ""} />
                  </div>
                </>
              ) : (
                <p className="mt-2 text-sm text-gray-700 dark:text-gray-300">{t("feedback_trigger_pr_review_text")}</p>
              )}
            </div>
          )
        })}
      </div>
    </section>
  )
}

function feedbackCreatedAtTime(entry: JobDetailPayload["feedback_history"][number]) {
  if (!entry.created_at) return 0
  const time = Date.parse(entry.created_at)
  return Number.isNaN(time) ? 0 : time
}

function feedbackTriggerLabel(triggerKind: string, t: ReturnType<typeof useT>["t"]) {
  if (triggerKind === "chat_feedback") return t("feedback_trigger_chat")
  if (triggerKind === "pr_comment") return t("feedback_trigger_pr")
  if (triggerKind === "external_pr_feedback") return t("feedback_trigger_external_pr")
  return triggerKind.replaceAll("_", " ")
}

type JobSummaryNotice = {
  id: string
  node: ReactNode
}

function JobSummaryNotices({
  command,
  payload,
  prefix,
  showUnsatisfiedDependencies
}: {
  command: JobCommand
  payload: JobDetailPayload
  prefix: string
  showUnsatisfiedDependencies: boolean
}) {
  const { t } = useT("jobs")
  const [currentIndex, setCurrentIndex] = useState(0)
  const notices = jobSummaryNotices({ command, payload, prefix, showUnsatisfiedDependencies })
  const activeIndex = Math.min(currentIndex, Math.max(notices.length - 1, 0))
  const notice = notices[activeIndex]
  const hasMultiple = notices.length > 1

  useEffect(() => {
    if (currentIndex >= notices.length) {
      setCurrentIndex(Math.max(notices.length - 1, 0))
    }
  }, [currentIndex, notices.length])

  if (!notice) return null

  return (
    <section aria-label={t("summary_notices")} className="space-y-2">
      <div className="flex flex-wrap items-center justify-between gap-2 text-xs text-text-secondary">
        <span className="font-medium">{t("summary_notice_position", { index: activeIndex + 1, count: notices.length })}</span>
        {hasMultiple ? (
          <div className="flex items-center gap-1">
            <button
              aria-label={t("previous_notice")}
              className="inline-flex h-7 w-7 items-center justify-center rounded border border-border bg-surface hover:bg-surface-muted disabled:opacity-40"
              onClick={() => setCurrentIndex((index) => (index - 1 + notices.length) % notices.length)}
              type="button"
            >
              <ChevronIcon className="h-4 w-4 rotate-180" />
            </button>
            <button
              aria-label={t("next_notice")}
              className="inline-flex h-7 w-7 items-center justify-center rounded border border-border bg-surface hover:bg-surface-muted disabled:opacity-40"
              onClick={() => setCurrentIndex((index) => (index + 1) % notices.length)}
              type="button"
            >
              <ChevronIcon className="h-4 w-4" />
            </button>
          </div>
        ) : null}
      </div>
      <div key={notice.id}>{notice.node}</div>
    </section>
  )
}

function jobSummaryNotices({
  command,
  payload,
  prefix,
  showUnsatisfiedDependencies
}: {
  command: JobCommand
  payload: JobDetailPayload
  prefix: string
  showUnsatisfiedDependencies: boolean
}): JobSummaryNotice[] {
  const notices: JobSummaryNotice[] = []
  const mergeTrainFailed = payload.merge_train_status?.phase === "failed"
  const prChecksFailing = payload.job.pr_checks?.state === "failing"
  const prChecksPending = payload.job.pr_checks?.state === "pending"

  if (mergeTrainFailed) notices.push({ id: "merge-train", node: <JobMergeTrainPanel payload={payload} /> })
  if (payload.job.landing_failure_reason) notices.push({ id: "landing-failed", node: <LandingFailedPanel payload={payload} /> })
  if (prChecksFailing) notices.push({ id: "pr-checks", node: <PrChecksBanner command={command} payload={payload} /> })
  if (payload.job.start_blocked_reason && !mainHealthBannerVisible(payload)) notices.push({ id: "start-blocked", node: <StartBlockedPanel payload={payload} /> })
  if (showUnsatisfiedDependencies) notices.push({ id: "dependencies", node: <UnsatisfiedDependencies command={command} payload={payload} /> })
  if (payload.merge_train_status && !mergeTrainFailed) notices.push({ id: "merge-train", node: <JobMergeTrainPanel payload={payload} /> })
  if (payload.landing_queue_entry) notices.push({ id: "landing-queue", node: <LandingQueuePanel payload={payload} prefix={prefix} /> })
  if (prChecksPending) notices.push({ id: "pr-checks", node: <PrChecksBanner command={command} payload={payload} /> })
  if (payload.job.retry_state && (payload.job.retry_state.state_label !== "No failure" || payload.job.retry_state.classification)) {
    notices.push({ id: "retry-state", node: <RetryStatePanel payload={payload} /> })
  }

  return notices
}

function JobMergeTrainPanel({ payload }: { payload: JobDetailPayload }) {
  const { t } = useT("jobs")
  const status = payload.merge_train_status
  if (!status) return null

  const tone = status.phase === "failed" ? "danger" : "info"
  return (
    <Notice tone={tone}>
      <span className="block font-medium">
        {t(`merge_train_phase.${status.phase}`, { defaultValue: status.phase })}
        {payload.epic ? ` · ${payload.epic.display_number}` : ""}
      </span>
      <span className="mt-1 block">{jobMergeTrainDetail(status, t)}</span>
      {status.branch ? <code className="mt-1 block break-all font-mono text-xs">{status.branch}</code> : null}
    </Notice>
  )
}

function jobMergeTrainDetail(status: NonNullable<JobDetailPayload["merge_train_status"]>, t: ReturnType<typeof useT>["t"]) {
  if (status.phase === "failed") return status.failure_reason ? t("merge_train_failed_with_reason", { reason: status.failure_reason }) : t("merge_train_failed")
  if (status.reconciliation?.result === "no_changes") return t("merge_train_reconcile_no_changes")
  if (status.reconciliation?.result === "committed") return t("merge_train_reconcile_committed")
  if (status.reconciliation?.result === "failed") return t("merge_train_reconcile_failed")
  if (status.current_step_label) return t("merge_train_current_step", { step: status.current_step_label })
  return t("merge_train_running")
}

function LandingQueuePanel({ payload, prefix }: { payload: JobDetailPayload; prefix: string }) {
  const { t } = useT("jobs")
  const entry = payload.landing_queue_entry
  if (!entry) return null

  return (
    <PanelMessage>
      {entry.position ? t("landing_queue_position", { position: entry.position }) : t("landing_queue")}
      {entry.blocked_reason ? (
        <>
          {" ("}
          {translateBlockedReason(entry.blocked_reason, t)}
          {entry.blocked_reason.key === "auto_merge_not_enabled" ? (
            <>
              {" — "}
              <Link
                className="font-medium text-brand underline hover:no-underline"
                to={withRoutePrefix(`${payload.repository.edit_repository_path}#auto-merge`, prefix)}
              >
                {t("landing_queue_enable_auto_merge")}
              </Link>
            </>
          ) : null}
          {")"}
        </>
      ) : (
        ""
      )}
      {entry.waiting_for_jobs.length > 0 ? (
        <>
          {" "}
          {t("landing_queue_waiting_for")}{" "}
          {entry.waiting_for_jobs.map((job, index) => (
            <span key={job.id}>
              {index > 0 ? ", " : null}
              <Link className="font-medium text-brand underline hover:no-underline" to={`${prefix}${job.job_path}`}>
                {job.label} {job.title}
              </Link>
            </span>
          ))}
        </>
      ) : null}
    </PanelMessage>
  )
}

function LandingFailedPanel({ payload }: { payload: JobDetailPayload }) {
  const { t } = useT("jobs")
  if (!payload.job.landing_failure_reason) return null

  return <PanelMessage tone="error">{t("landing_failed", { reason: payload.job.landing_failure_reason })}</PanelMessage>
}

function PrChecksBanner({ command, payload }: { command: JobCommand; payload: JobDetailPayload }) {
  const { t } = useT("jobs")
  const checks = payload.job.pr_checks
  if (!checks || (checks.state !== "failing" && checks.state !== "pending")) return null

  const sha = checks.short_sha || t("pr_checks_unknown_sha")
  const message = checks.state === "failing" ? t("pr_checks_failing", { sha }) : t("pr_checks_pending", { sha })

  const attribution = checks.attribution
  // An inherited failure is not this Job's fault, so it should not be dressed in
  // the same red as one this Job introduced.
  const tone = checks.state !== "failing" || attribution?.verdict === "inherited" ? "muted" : "error"
  const blockerKey = payload.landing_queue_entry?.blocked_reason?.key
  const prChecksBlocker =
    blockerKey === "pr_checks_failing_inherited" || blockerKey === "pr_checks_failing_base_unknown" || blockerKey === "pr_checks_failing_base_stale"
  const overridePath = payload.landing_queue_entry?.override_path
  const overrideCommandPath = overridePath || null
  const recheckPath = payload.paths.app_recheck_pr_checks_path
  const canOverride = Boolean(
    prChecksBlocker &&
    (payload.actions.can_override_pr_checks_landing_blocker || payload.actions.can_override_inherited_pr_checks) &&
    overrideCommandPath &&
    blockerKey
  )
  const canRecheck = Boolean(payload.actions.can_recheck_pr_checks && recheckPath)

  return (
    <PanelMessage tone={tone}>
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div className="min-w-0">
          {message}
          {checks.checks_url ? (
            <>
              {" "}
              <a className="font-medium text-brand underline hover:no-underline" href={checks.checks_url} rel="noopener" target="_blank">
                {t("pr_checks_view_github")}
              </a>
            </>
          ) : null}
          {checks.sha ? <div className="mt-1 font-mono text-xs">{t("pr_checks_head_sha", { sha: checks.sha.slice(0, 12) })}</div> : null}
          {checks.base_sha ? <div className="font-mono text-xs">{t("pr_checks_payload_base_sha", { sha: checks.base_sha.slice(0, 12) })}</div> : null}
        </div>
        {canRecheck || canOverride ? (
          <div className="flex shrink-0 flex-wrap gap-2">
            {canRecheck ? (
              <CommandButton command={command} input={{ method: "post", path: recheckPath! }} tone="secondary">
                {t("recheck_pr_checks")}
              </CommandButton>
            ) : null}
            {canOverride && overrideCommandPath && blockerKey ? (
              <CommandButton
                command={command}
                input={{
                  method: "post",
                  path: overrideCommandPath,
                  body: {
                    blocker_key: blockerKey,
                    reason: t("pr_checks_override_reason")
                  },
                  confirm: t("pr_checks_override_confirm")
                }}
                tone="secondary"
              >
                {t("pr_checks_override_once")}
              </CommandButton>
            ) : null}
          </div>
        ) : null}
      </div>
      {attribution ? <PrCheckAttributionDetail attribution={attribution} /> : null}
    </PanelMessage>
  )
}

// Shows the comparison, not just the verdict: which checks are red here, which
// of those were already red on the base, and which base was compared. Without
// this an operator cannot check the call, and neither can an agent.
function PrCheckAttributionDetail({ attribution }: { attribution: JobPrCheckAttribution }) {
  const { t } = useT("jobs")
  const label =
    attribution.verdict === "inherited"
      ? t("pr_checks_attribution_inherited")
      : attribution.verdict === "own"
        ? t("pr_checks_attribution_own")
        : t("pr_checks_attribution_unknown")

  return (
    <div className="mt-2 text-xs">
      <div className="font-semibold uppercase tracking-wide">{label}</div>
      <dl className="mt-1 grid gap-x-4 gap-y-0.5 sm:grid-cols-[auto_1fr]">
        {attribution.failing_names.length > 0 ? (
          <>
            <dt className="text-gray-600 dark:text-gray-400">{t("pr_checks_attribution_failing")}</dt>
            <dd className="font-mono">{attribution.failing_names.join(", ")}</dd>
          </>
        ) : null}
        {attribution.base_failing_names.length > 0 ? (
          <>
            <dt className="text-gray-600 dark:text-gray-400">{t("pr_checks_attribution_base_failing")}</dt>
            <dd className="font-mono">{attribution.base_failing_names.join(", ")}</dd>
          </>
        ) : null}
      </dl>
      {attribution.base_sha ? (
        <div className="mt-1 text-gray-600 dark:text-gray-400">{t("pr_checks_attribution_base", { sha: attribution.base_sha.slice(0, 7) })}</div>
      ) : null}
    </div>
  )
}

// The main-branch-health banner above carries its own copy and a link to the
// repository, so it owns that reason wherever it renders.
//
// It used to require `state === "queued"`, which is only true before the
// Workflow starts. A Job blocked mid-chain -- after an implement step, say --
// is `running`, so the one banner that would have explained the wait was the
// one surface guaranteed not to show it. The gate is now the block itself.
const MAIN_HEALTH_REASONS = [ "main_branch_health", "main_branch_broken" ]
const EPIC_DEPENDENCY_NO_MATCHES_CLASS = "absolute left-0 right-0 top-full z-20 mt-1 rounded border border-gray-200 bg-white px-3 py-1.5 text-sm text-gray-400 shadow-lg dark:border-gray-700 dark:bg-gray-900 dark:text-gray-500"
const ATTACHMENT_REMOVE_BUTTON_CLASS = "absolute right-2 top-2 rounded border border-red-200 bg-white px-2 py-1 text-xs text-red-700 hover:bg-red-50 dark:border-red-900 dark:bg-gray-950 dark:text-red-300 dark:hover:bg-red-950/40"

function mainHealthBannerVisible(payload: JobDetailPayload) {
  if (payload.job.state === "closed" || payload.job.state === "failed") return false
  if (!payload.repository.landing_paused) return false
  if (payload.repository.main_health !== "broken") return false
  if (!payload.repository.main_branch_repair_blocks_work) return false

  return payload.job.state === "queued" || MAIN_HEALTH_REASONS.includes(payload.job.start_blocked_reason ?? "")
}

// Every reason Syrus is not working on this job, not just admission budget.
// This panel used to return null unless the job was `queued` AND blocked on
// `workflow_admission_budget`, so a job stopped mid-chain for any other
// reason -- main-branch health being the one that strands jobs for hours --
// rendered no explanation at all on its own detail page. The admission
// breakdown is now the optional extra, not the price of admission.
function StartBlockedPanel({ payload }: { payload: JobDetailPayload }) {
  const { t } = useT("jobs")
  const reason = payload.job.start_blocked_reason
  if (!reason) return null
  if (mainHealthBannerVisible(payload)) return null

  const breakdown = payload.job.start_blocked_breakdown
  const showBreakdown = reason === "workflow_admission_budget" && !!breakdown
  const diagnosticsPath = payload.actions.can_view_resource_admission_diagnostics ? payload.paths.admin_resource_admission_path : null
  const telemetryMessage = breakdown?.telemetry_state === "absent" ? t("admission_breakdown_telemetry_absent") : t("admission_breakdown_telemetry_stale")

  return (
    <Notice tone="warning">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <span className="font-semibold">{showBreakdown ? t("admission_breakdown_title") : t("start_blocked_title")}</span>
        <StartBlockedReasonPill
          count={payload.job.start_blocked_count}
          details={payload.job.start_blocked_details}
          diagnosticsPath={diagnosticsPath}
          nextCheckAt={payload.job.start_blocked_next_check_at}
          reason={reason}
          startBlockedAt={payload.job.start_blocked_at}
        />
      </div>
      {showBreakdown ? null : (
        <p className="mt-1">{t(`common:start_blocked_reason_tooltips.${reason}`, { defaultValue: t("start_blocked_generic") })}</p>
      )}
      {showBreakdown && breakdown ? (
      <>
      <p className="mt-1">{t(`admission_breakdown_category_${breakdown.category}`, { defaultValue: t("admission_breakdown_category_other") })}</p>
      {breakdown.telemetry_absent ? (
        <p className="mt-2 rounded-[var(--radius-panel)] border border-warning-border bg-warning-surface px-2 py-1.5 text-xs font-medium" role="status">
          {telemetryMessage}
        </p>
      ) : null}
      {breakdown.dimensions.length > 0 ? (
        <ul className="mt-2 space-y-1 text-xs">
          {breakdown.dimensions.map((dimension) => (
            <li className={dimension.over_threshold ? "font-semibold" : ""} key={dimension.metric}>
              {t("admission_breakdown_dimension", { current: dimension.current, label: dimension.label, threshold: dimension.threshold })}
            </li>
          ))}
        </ul>
      ) : null}
      </>
      ) : null}
    </Notice>
  )
}

function RetryStatePanel({ payload }: { payload: JobDetailPayload }) {
  const { t } = useT("jobs")
  const retry = payload.job.retry_state
  if (!retry || (retry.state_label === "No failure" && !retry.classification)) return null

  const tone = retry.auto_retry_exhausted ? "danger" : retry.provider_circuit_open ? "warning" : "neutral"
  return (
    <Notice tone={tone}>
      <div className="flex flex-wrap items-center gap-2">
        <span className="font-semibold">{retry.state_label}</span>
        <SmallPill>{retry.classification_label}</SmallPill>
        <SmallPill>{retry.retryable ? t("run_retryable") : t("run_not_retryable")}</SmallPill>
        <SmallPill>
          {retry.retry_attempt_count}/{retry.retry_budget} {t("retry_attempts_label")}
        </SmallPill>
        <SmallPill>
          {retry.retry_budget_remaining} {t("retry_remaining_label")}
        </SmallPill>
      </div>
      <div className="mt-1 flex flex-wrap gap-x-4 gap-y-1 text-xs">
        {retry.next_auto_retry_at ? (
          <span>
            {t("retry_state_next_retry")} <RelativeTimestamp value={retry.next_auto_retry_at} />
          </span>
        ) : null}
        {retry.retry_delayed_until ? (
          <span>
            {t("retry_state_delayed_until")} <RelativeTimestamp value={retry.retry_delayed_until} />
          </span>
        ) : null}
        {retry.retry_delay_reason ? <span>{retry.retry_delay_reason}</span> : null}
      </div>
    </Notice>
  )
}

function JobOwnerLabel({ payload, command, prefix }: { payload: JobDetailPayload; command: ReturnType<typeof useJobCommand>; prefix: string }) {
  const { t } = useT("jobs")
  const owner = payload.job.claimed_by_user

  return (
    <span className="inline-flex flex-wrap items-center gap-2">
      {owner ? (
        <>
          <Link className="font-medium text-brand hover:underline" to={withRoutePrefix(owner.profile_path, prefix)}>
            {payload.job.claimed_by_current_user ? t("owner_you") : owner.display_name}
          </Link>
          {payload.job.claimed_at ? (
            <span className="text-xs text-gray-400 dark:text-gray-500">
              <RelativeTimestamp value={payload.job.claimed_at} />
            </span>
          ) : null}
        </>
      ) : (
        <span className="text-gray-400 dark:text-gray-500">{t("owner_unclaimed")}</span>
      )}
      {payload.actions.can_claim ? (
        <button
          className="text-xs font-medium text-brand hover:underline disabled:cursor-not-allowed disabled:opacity-50"
          disabled={command.isPending}
          onClick={() => command.mutate({ method: "post", path: payload.paths.app_claim_path })}
          type="button"
        >
          {t("owner_claim")}
        </button>
      ) : null}
      {payload.actions.can_unclaim ? (
        <button
          className="text-xs text-gray-500 hover:underline disabled:cursor-not-allowed disabled:opacity-50 dark:text-gray-400"
          disabled={command.isPending}
          onClick={() => command.mutate({ method: "delete", path: payload.paths.app_claim_path })}
          type="button"
        >
          {t("owner_release")}
        </button>
      ) : null}
    </span>
  )
}

function UnsatisfiedDependencies({ payload, command }: { payload: JobDetailPayload; command: ReturnType<typeof useJobCommand> }) {
  const { t } = useT("jobs")
  const count = payload.unsatisfied_dependencies.length
  return (
    <Notice tone="warning">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <span className="font-medium">{t("blocked_on", { count })}</span>
          <span className="ml-2 inline-flex flex-wrap gap-x-2 gap-y-1">
            {payload.unsatisfied_dependencies.map((dependency, index) => (
              <span key={dependency.id}>
                {index > 0 ? <span className="mr-2">,</span> : null}
                <DependencyLink dependency={dependency} />
              </span>
            ))}
          </span>
          <span className="ml-1">{count === 1 ? t("blocked_auto_start_one") : t("blocked_auto_start_other")}</span>
        </div>
        {payload.actions.can_override_dependencies ? (
          <CommandButton
            command={command}
            input={{ method: "post", path: payload.paths.app_dependency_override_path, confirm: t("confirm_override_dependencies") }}
            tone="danger-outline"
          >
            {t("override_and_force_run")}
          </CommandButton>
        ) : null}
      </div>
    </Notice>
  )
}

function StackBaseForm({ payload, command }: { payload: JobDetailPayload; command: ReturnType<typeof useJobCommand> }) {
  const { t } = useT("jobs")
  const [stackBase, setStackBase] = useState(payload.job.stack_base)

  useEffect(() => setStackBase(payload.job.stack_base), [payload.job.stack_base])

  return (
    <form
      className="flex flex-wrap items-center gap-2"
      onSubmit={(event) => {
        event.preventDefault()
        command.mutate({ method: "patch", path: payload.paths.app_stack_base_path, body: { stack_base: stackBase } })
      }}
    >
      <Select className="px-2 py-1 text-xs" fullWidth={false} onChange={(event) => setStackBase(event.target.value)} value={stackBase}>
        <option value="auto">auto</option>
        <option value="main">main</option>
      </Select>
      <button className="text-xs text-brand hover:underline" disabled={command.isPending} type="submit">
        {t("stack_base_update")}
      </button>
    </form>
  )
}

function PullRequestSummary({ payload }: { payload: JobDetailPayload }) {
  const { t } = useT("jobs")
  if (!payload.job.pr_number && !payload.job.external_pr_number) return <span className="text-gray-400 dark:text-gray-500">-</span>

  return (
    <div className="space-y-1">
      {payload.job.pr_number ? (
        <a className="text-brand hover:underline" href={payload.job.pr_url || "#"} rel="noopener" target="_blank">
          {t("pr_syrus", { number: payload.job.pr_number })}
        </a>
      ) : null}
      {payload.job.external_pr_number ? (
        <a className="block text-violet-700 hover:underline" href={payload.job.external_pr_url || "#"} rel="noopener" target="_blank">
          {t("pr_external", { number: payload.job.external_pr_number })}
        </a>
      ) : null}
      <div>
        <MergeablePill value={payload.job.pr_mergeable} />{" "}
        {payload.job.pr_mergeable_checked_at ? (
          <span className="text-xs text-gray-400 dark:text-gray-500">
            {t("pr_checked")} <RelativeTimestamp value={payload.job.pr_mergeable_checked_at} />
          </span>
        ) : null}
      </div>
    </div>
  )
}

function InvalidationEvidenceList({ urls }: { urls: string[] }) {
  return (
    <ul className="space-y-0.5">
      {urls.map((url) => (
        <li key={url}>
          <a className="block truncate text-brand hover:underline" href={url} rel="noopener" target="_blank">
            {url}
          </a>
        </li>
      ))}
    </ul>
  )
}

function ApprovalStatusPanel({ payload, prefix }: { payload: JobDetailPayload; prefix: string }) {
  const { t } = useT("jobs")
  const { job, repository } = payload
  const status: JobApprovalStatus | null = job.approval_status
  const approvals: JobApprovalRecord[] = job.job_approvals ?? []

  const policyLabel: Record<string, string> = {
    self: t("approval_policy_self"),
    two_person: t("approval_policy_two_person"),
    final_say: t("approval_policy_final_say")
  }

  if (!status && approvals.length === 0 && repository.review_policy === "self") return null

  return (
    <div className="rounded border border-gray-200 bg-white p-4 text-sm dark:border-gray-700 dark:bg-gray-900">
      <SectionHeading>{t("section_approval")}</SectionHeading>
      <div className="mt-2 space-y-2">
        <div className="flex items-center justify-between">
          <span className="text-gray-500 dark:text-gray-400">{t("approval_policy")}</span>
          <span className="text-gray-700 dark:text-gray-300">{policyLabel[repository.review_policy] ?? repository.review_policy}</span>
        </div>
        {status && (
          <div className="flex items-center justify-between">
            <span className="text-gray-500 dark:text-gray-400">{t("approval_status")}</span>
            {status.satisfied ? (
              <span className="font-medium text-emerald-600 dark:text-emerald-400">{t("approval_satisfied")}</span>
            ) : (
              <span className="text-amber-600 dark:text-amber-400">{status.pending_description ?? t("approval_pending")}</span>
            )}
          </div>
        )}
        {job.approval_evidence ? <AutoApprovalEvidenceNote evidence={job.approval_evidence} prefix={prefix} /> : null}
        {approvals.length > 0 ? (
          <div>
            <span className="text-gray-500 dark:text-gray-400">{t("approval_approvals")}</span>
            <ul className="mt-1 divide-y divide-gray-100 dark:divide-gray-800">
              {approvals.map((approval) => (
                <li key={approval.id} className="flex items-center justify-between py-1 text-xs">
                  <span className="truncate text-gray-700 dark:text-gray-300">{approval.user_email}</span>
                  <span className="ml-2 shrink-0 text-gray-400 dark:text-gray-500">
                    <RelativeTimestamp value={approval.approved_at} />
                  </span>
                </li>
              ))}
            </ul>
          </div>
        ) : (
          <p className="text-xs text-gray-400 dark:text-gray-500">{t("no_approvals")}</p>
        )}
      </div>
    </div>
  )
}

function AutoApprovalEvidenceNote({ evidence, prefix }: { evidence: JobApprovalEvidence; prefix: string }) {
  const { t } = useT("jobs")

  return (
    <p className="rounded bg-emerald-50 px-2 py-1.5 text-xs text-emerald-800 dark:bg-emerald-950/40 dark:text-emerald-200">
      {t("approval_evidence_auto_approved", { rule: evidence.rule })}
      {evidence.source ? <> · {t("approval_evidence_source", { source: evidence.source })}</> : null}
      {evidence.grader_step_workflow_path ? (
        <>
          {" "}
          ·{" "}
          <Link className="underline hover:no-underline" to={withRoutePrefix(evidence.grader_step_workflow_path, prefix)}>
            {t("approval_evidence_grader_step_link")}
          </Link>
        </>
      ) : null}
    </p>
  )
}

function DependenciesPanel({ payload, command }: { payload: JobDetailPayload; command: ReturnType<typeof useJobCommand> }) {
  const { t } = useT("jobs")
  const [query, setQuery] = useState("")
  const [addingDependency, setAddingDependency] = useState(false)
  const [epicQuery, setEpicQuery] = useState("")
  const [addingEpicDependency, setAddingEpicDependency] = useState(false)
  const dependencyOptions = useQuery({
    queryKey: ["job", payload.job.id, "dependency_options"],
    queryFn: () =>
      fetchJobDependencyOptions(
        payload.paths.app_dependency_options_path || `${payload.paths.app_dependencies_path.replace(/\/dependencies$/, "")}/dependency_options`
      ),
    enabled: addingDependency || addingEpicDependency,
    staleTime: 30000
  })
  const jobDependencyOptions = dependencyOptions.data?.dependency_target_options ?? payload.dependency_target_options
  const epicDependencyOptions = dependencyOptions.data?.epic_dependency_target_options ?? payload.epic_dependency_target_options

  const trimmedQuery = query.trim()
  const filteredOptions =
    trimmedQuery.length > 0 ? jobDependencyOptions.filter((option) => option.label.toLowerCase().includes(trimmedQuery.toLowerCase())) : jobDependencyOptions

  const trimmedEpicQuery = epicQuery.trim()
  const filteredEpicOptions =
    trimmedEpicQuery.length > 0
      ? epicDependencyOptions.filter((option) => option.label.toLowerCase().includes(trimmedEpicQuery.toLowerCase()))
      : epicDependencyOptions

  function choose(value: string) {
    command.mutate(
      { method: "post", path: payload.paths.app_dependencies_path, body: { dependency_target: value } },
      {
        onSuccess: () => {
          setQuery("")
          setAddingDependency(false)
        }
      }
    )
  }

  function chooseEpic(epicId: number) {
    command.mutate(
      { method: "post", path: payload.paths.app_epic_dependencies_path, body: { depends_on_epic_id: epicId } },
      {
        onSuccess: () => {
          setEpicQuery("")
          setAddingEpicDependency(false)
        }
      }
    )
  }

  function cancelAdding() {
    setQuery("")
    setAddingDependency(false)
  }

  function cancelAddingEpic() {
    setEpicQuery("")
    setAddingEpicDependency(false)
  }

  return (
    <div className="space-y-4">
      <div className="rounded border border-gray-200 bg-white p-4 text-sm dark:border-gray-700 dark:bg-gray-900">
        <SectionHeading>{t("section_dependencies")}</SectionHeading>
        {payload.dependencies.length > 0 ? (
          <ul className="mt-2 divide-y divide-gray-100 dark:divide-gray-800">
            {payload.dependencies.map((dependency) => {
              const epicTarget = dependency.depends_on_epic
              return (
                <li className="flex flex-wrap items-center justify-between gap-2 py-2" key={dependency.id}>
                  <span className="flex flex-wrap items-center gap-2">
                    <span>
                      <DependencyLink dependency={dependency} /> <span className="text-xs text-gray-400 dark:text-gray-500">({dependency.source})</span>
                    </span>
                    {!dependency.succeeded ? <TonePill tone="amber">{t("dependency_not_yet_satisfied")}</TonePill> : null}
                  </span>
                  {dependency.manual && !epicTarget ? (
                    <button
                      className="text-xs text-red-600 hover:underline"
                      disabled={command.isPending}
                      onClick={() =>
                        command.mutate({
                          method: "delete",
                          path: `${payload.paths.app_dependencies_path}/${dependency.id}`,
                          confirm: t("confirm_remove_dependency")
                        })
                      }
                      type="button"
                    >
                      {t("remove_dependency")}
                    </button>
                  ) : null}
                  {dependency.manual && epicTarget ? (
                    <button
                      className="text-xs text-red-600 hover:underline"
                      disabled={command.isPending}
                      onClick={() =>
                        command.mutate({
                          method: "delete",
                          path: `${payload.paths.app_epic_dependencies_path}/${epicTarget.id}`,
                          confirm: t("confirm_remove_epic_dependency", { slug: epicTarget.slug })
                        })
                      }
                      type="button"
                    >
                      {t("remove_dependency")}
                    </button>
                  ) : null}
                </li>
              )
            })}
          </ul>
        ) : (
          <p className="mt-2 text-gray-400 dark:text-gray-500">{t("section_no_dependencies")}</p>
        )}
        {addingDependency ? (
          <div className="mt-3 border-t border-gray-100 pt-3 dark:border-gray-800">
            <label className="block text-xs font-medium uppercase text-gray-500 dark:text-gray-400">
              {t("dependency_search_label")}
              <div className="relative mt-1">
                <Input
                  aria-autocomplete="list"
                  autoFocus
                  className="normal-case"
                  disabled={command.isPending}
                  onChange={(event) => setQuery(event.target.value)}
                  placeholder={t("dependency_search_placeholder")}
                  type="search"
                  value={query}
                />
                {filteredOptions.length > 0 ? (
                  <div className="absolute left-0 right-0 top-full z-20 mt-1 max-h-56 overflow-y-auto rounded border border-gray-200 bg-white py-1 shadow-lg dark:border-gray-700 dark:bg-gray-900">
                    {filteredOptions.map((option) => (
                      <button
                        className="block w-full px-3 py-1.5 text-left text-sm text-gray-700 hover:bg-gray-50 disabled:opacity-50 dark:text-gray-200 dark:hover:bg-gray-800"
                        disabled={command.isPending}
                        key={option.value}
                        onClick={() => choose(option.value)}
                        type="button"
                      >
                        {option.label}
                      </button>
                    ))}
                  </div>
                ) : trimmedQuery.length > 0 ? (
                  <div className={EPIC_DEPENDENCY_NO_MATCHES_CLASS}>
                    {t("dependency_no_matches")}
                  </div>
                ) : null}
              </div>
            </label>
            <button
              className="mt-2 text-xs text-gray-500 hover:underline disabled:cursor-not-allowed disabled:opacity-50"
              disabled={command.isPending}
              onClick={cancelAdding}
              type="button"
            >
              {t("cancel")}
            </button>
          </div>
        ) : addingEpicDependency ? (
          <div className="mt-3 border-t border-gray-100 pt-3 dark:border-gray-800">
            <label className="block text-xs font-medium uppercase text-gray-500 dark:text-gray-400">
              {t("epic_dependency_search_label")}
              <div className="relative mt-1">
                <Input
                  aria-autocomplete="list"
                  autoFocus
                  className="normal-case"
                  disabled={command.isPending}
                  onChange={(event) => setEpicQuery(event.target.value)}
                  placeholder={t("dependency_search_placeholder")}
                  type="search"
                  value={epicQuery}
                />
                {filteredEpicOptions.length > 0 ? (
                  <div className="absolute left-0 right-0 top-full z-20 mt-1 max-h-56 overflow-y-auto rounded border border-gray-200 bg-white py-1 shadow-lg dark:border-gray-700 dark:bg-gray-900">
                    {filteredEpicOptions.map((option) => (
                      <button
                        className="block w-full px-3 py-1.5 text-left text-sm text-gray-700 hover:bg-gray-50 disabled:opacity-50 dark:text-gray-200 dark:hover:bg-gray-800"
                        disabled={command.isPending}
                        key={option.value}
                        onClick={() => chooseEpic(option.value)}
                        type="button"
                      >
                        {option.label}
                      </button>
                    ))}
                  </div>
                ) : trimmedEpicQuery.length > 0 ? (
                  <div className="absolute left-0 right-0 top-full z-20 mt-1 rounded border border-gray-200 bg-white px-3 py-1.5 text-sm text-gray-400 shadow-lg dark:border-gray-700 dark:bg-gray-900 dark:text-gray-500">
                    {t("epic_dependency_no_matches")}
                  </div>
                ) : null}
              </div>
            </label>
            <button
              className="mt-2 text-xs text-gray-500 hover:underline disabled:cursor-not-allowed disabled:opacity-50"
              disabled={command.isPending}
              onClick={cancelAddingEpic}
              type="button"
            >
              {t("cancel")}
            </button>
          </div>
        ) : (
          <div className="mt-3 flex flex-wrap gap-3 border-t border-gray-100 pt-3 dark:border-gray-800">
            <button className="text-xs font-medium text-brand hover:underline" onClick={() => setAddingDependency(true)} type="button">
              {t("add_dependency")}
            </button>
            {epicDependencyOptions.length > 0 || !dependencyOptions.isSuccess ? (
              <button className="text-xs font-medium text-brand hover:underline" onClick={() => setAddingEpicDependency(true)} type="button">
                {t("add_epic_dependency")}
              </button>
            ) : null}
          </div>
        )}
      </div>
      {payload.dependents.length > 0 ? (
        <div className="rounded border border-gray-200 bg-white p-4 text-sm dark:border-gray-700 dark:bg-gray-900">
          <SectionHeading>{t("dependents_title", { count: payload.dependents.length })}</SectionHeading>
          <ul className="mt-2 divide-y divide-gray-100 dark:divide-gray-800">
            {payload.dependents.map((dependent) => (
              <li className="flex flex-wrap items-center gap-2 py-2" key={dependent.id}>
                <JobDependencyTargetReference target={dependent.job} />
              </li>
            ))}
          </ul>
        </div>
      ) : null}
    </div>
  )
}

export function ArtifactsTab({ artifacts }: { artifacts: TypedArtifact[] }) {
  const { t } = useT("jobs")

  if (artifacts.length === 0) {
    return <PanelMessage>{t("section_no_artifacts")}</PanelMessage>
  }

  return (
    <section className="min-w-0 space-y-4">
      {artifacts.map((artifact) => (
        <div className="min-w-0 overflow-hidden rounded border border-gray-200 bg-white p-4 dark:border-gray-700 dark:bg-gray-900" key={artifact.type}>
          <SectionHeading className="break-words">{artifact.title}</SectionHeading>
          <div className="mt-3 overflow-x-auto">
            <ArtifactBody artifact={artifact} />
          </div>
        </div>
      ))}
    </section>
  )
}

function AttachmentsTab({
  payload,
  queryKey,
  onNotice
}: {
  payload: JobDetailPayload
  queryKey: JobDetailQueryKey
  onNotice: (message: string | null) => void
}) {
  const { t } = useT("jobs")
  const queryClient = useQueryClient()
  const [files, setFiles] = useState<File[]>([])
  const [googleDocUrl, setGoogleDocUrl] = useState("")
  const add = useMutation({
    mutationFn: () => createJobAttachments(payload.paths.app_attachments_path, { files, googleDocUrl }),
    onSuccess: (result) => {
      onNotice(result.message || null)
      setFiles([])
      setGoogleDocUrl("")
      void queryClient.invalidateQueries({ queryKey })
      void queryClient.invalidateQueries({ queryKey: ["jobs", String(payload.job.id)] })
    }
  })
  const remove = useMutation({
    mutationFn: (path: string) => deleteJobCommand(path),
    onSuccess: (result) => {
      onNotice(result.message || null)
      void queryClient.invalidateQueries({ queryKey })
      void queryClient.invalidateQueries({ queryKey: ["jobs", String(payload.job.id)] })
    }
  })

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    add.mutate()
  }

  return (
    <section className="space-y-4">
      <form className="rounded border border-gray-200 bg-white p-4 dark:border-gray-700 dark:bg-gray-900" onSubmit={submit}>
        <SectionHeading>{t("attachment_add_title")}</SectionHeading>
        <div className="mt-3 grid gap-3 md:grid-cols-[minmax(0,1fr)_minmax(0,1fr)_auto] md:items-end">
          <label className="text-sm font-medium text-gray-700 dark:text-gray-300">
            {t("attachment_files_label")}
            <Input className="mt-1 text-sm" multiple onChange={(event) => setFiles(Array.from(event.target.files || []))} type="file" />
          </label>
          <label className="text-sm font-medium text-gray-700 dark:text-gray-300">
            {t("attachment_google_doc_label")}
            <Input
              className="mt-1"
              onChange={(event) => setGoogleDocUrl(event.target.value)}
              placeholder={t("attachment_google_doc_placeholder")}
              type="url"
              value={googleDocUrl}
            />
          </label>
          <Button disabled={add.isPending || (files.length === 0 && googleDocUrl.trim() === "")} type="submit">
            {t("attachment_add_button")}
          </Button>
        </div>
        {add.isError ? <p className="mt-2 text-sm text-red-700">{errorMessage(add.error, t("attachment_add_error"))}</p> : null}
      </form>

      {payload.attachments.length > 0 ? (
        <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
          {payload.attachments.map((attachment) => (
            <div className="relative" key={attachment.id}>
              <AttachmentCard attachment={attachment} />
              <button
                className={ATTACHMENT_REMOVE_BUTTON_CLASS}
                disabled={remove.isPending}
                onClick={() => remove.mutate(attachment.app_delete_path)}
                type="button"
              >
                {t("attachment_remove")}
              </button>
            </div>
          ))}
        </div>
      ) : (
        <PanelMessage>{t("section_no_attachments")}</PanelMessage>
      )}
      {remove.isError ? <PanelMessage tone="error">{errorMessage(remove.error, t("attachment_remove_error"))}</PanelMessage> : null}
    </section>
  )
}
