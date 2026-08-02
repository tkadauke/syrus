import { RelativeTimestamp } from "../components/RelativeTimestamp"
import { keepPreviousData, useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import type { FormEvent } from "react"
import { useEffect, useState } from "react"
import { Link, useLocation, useNavigate, useParams } from "react-router-dom"
import { useT } from "../hooks/useT"
import { usePageTitle } from "../hooks/usePageTitle"
import { KeyValue } from "../components/KeyValue"
import { CopyableSlug } from "../components/CopyableSlug"
import { NoticeToast } from "../components/NoticeToast"
import { StatusPill, TonePill } from "../components/StatusPill"
import { Markdown } from "../lib/Markdown"
import { translateBlockedReason } from "../lib/translateBlockedReason"
import { workflowSlug } from "../lib/slugs"
import { buttonClass } from "../lib/buttonClasses"
import { applyPendingFeedback, createJobAttachments, deleteJobCommand, fetchJobDependencyOptions, fetchJobDetail, fetchJobTestResults, fetchJobWorkflows, ignorePendingFeedback, replacePendingFeedback, retryPendingFeedback, submitJobFeedback, updateJobPriority, updateJobProviderSetting, type JobApprovalRecord, type JobApprovalStatus, type JobDeploymentStage, type JobDetailPayload, type JobTestCase, type JobTestPlan, type JobTestRun, type JobTestSuite, type JobWorkflow, type PendingFeedbackComment } from "../api/jobs"
import { CoverageCard } from "../components/CoverageCard"
import { ProviderAvailabilityWarning } from "../components/ProviderAvailabilityWarning"
import { SyrusTour } from "../components/SyrusTour"
import { useTour } from "../hooks/useTour"
import { errorMessage } from "../lib/errorMessage"
import type { JobDetailQueryKey, JobTab, JobWorkflowsQueryKey } from "./jobDetail/queryKeys"
import { CommandButton, useJobCommand } from "./jobDetail/command"
import { TagsPanel, NeedsAttentionBanner, FeedbackSourceBadge, EpicSummaryLink, TimelinePanel, AttachmentPreview, AttachmentCard, MergeablePill, JobStateBadge, PendingJobTitle, JobSourceLink, DependencyLink, JobDependencyTargetReference, PanelMessage, SmallPill, jobSourceLabel } from "./jobDetail/components"
import { ChatBubbleIcon, HeaderActions, JobFeedbackPanel } from "./jobDetail/JobHeader"
import { jobDetailQueryKey, jobDetailSearch, jobWorkflowsQueryKey, mergeJobWorkflowsPayload, tabFromLocation } from "./jobDetail/queryKeys"
import { formatCurrency, jobSlug, withRoutePrefix } from "./jobDetail/formatting"
import { latestWorkflowCoverage, workflowCreatedAtTime } from "./jobDetail/workflowArtifacts"
import { WorkflowsTab } from "./jobDetail/WorkflowGraph"
import { SourceTab } from "./jobDetail/SourceBrowser"

export function JobDetailRoute() {
  const { t } = useT("jobs")
  const params = useParams()
  const location = useLocation()
  const navigate = useNavigate()
  const id = params.id || ""
  const activeTab = tabFromLocation(location.pathname, location.search)
  const prefix = location.pathname.startsWith("/app-shell") ? "/app-shell" : ""
  const detailSearch = jobDetailSearch(location.search)
  const queryKey = jobDetailQueryKey(id, detailSearch)
  const workflowsQueryKey = jobWorkflowsQueryKey(id, detailSearch)
  const detail = useQuery({
    queryKey,
    queryFn: () => fetchJobDetail(id, detailSearch),
    enabled: id.length > 0
  })
  const workflows = useQuery({
    queryKey: workflowsQueryKey,
    queryFn: () => fetchJobWorkflows(id, detailSearch),
    enabled: id.length > 0 && activeTab === "workflows" && detail.isSuccess,
    placeholderData: keepPreviousData
  })
  const payload = detail.isSuccess ? mergeJobWorkflowsPayload(detail.data, workflows.data) : null
  const job = detail.data?.job
  const pageTitle = job
    ? (job.issue_title ? `${jobSlug(job.id)}: ${job.issue_title}` : jobSlug(job.id))
    : (id ? `JOB-${id}` : undefined)
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
    <main aria-label={t("aria_job")} className="mx-auto max-w-[96rem] space-y-6 p-6">
      {detail.isPending ? <PanelMessage>{t("loading")}</PanelMessage> : null}
      {detail.isError ? <PanelMessage tone="error">{errorMessage(detail.error, t("load_error"))}</PanelMessage> : null}
      {payload ? <JobDetailView activeTab={activeTab} onSelectTab={selectTab} payload={payload} prefix={prefix} queryKey={queryKey} workflowsQueryKey={workflowsQueryKey} /> : null}
    </main>
  )
}

export function JobDetailView({ payload, queryKey, workflowsQueryKey, activeTab, onSelectTab, prefix }: { payload: JobDetailPayload; queryKey: JobDetailQueryKey; workflowsQueryKey?: JobWorkflowsQueryKey; activeTab: JobTab; onSelectTab: (tab: JobTab) => void; prefix: string }) {
  const { t } = useT("jobs")
  const { t: tTours } = useT("tours")
  const location = useLocation()
  const queryClient = useQueryClient()
  const [notice, setNotice] = useState<string | null>(payload.message || null)
  const [feedbackPanelOpen, setFeedbackPanelOpen] = useState(false)
  const command = useJobCommand(payload.job.id, queryKey, workflowsQueryKey, setNotice)
  const title = payload.job.issue_title || jobSourceLabel(payload, t)
  const workflowAnchor = location.hash.startsWith("#workflow-") ? location.hash.slice(1) : null
  const renderedWorkflowIds = payload.workflows.map((workflow) => workflow.id).join(",")
  const feedback = useMutation({
    mutationFn: (body: string) => submitJobFeedback(payload.job.id, body),
    onSuccess: () => {
      setFeedbackPanelOpen(false)
      setNotice(t("feedback_submitted"))
      void queryClient.invalidateQueries({ queryKey })
      if (workflowsQueryKey) void queryClient.invalidateQueries({ queryKey: workflowsQueryKey })
    }
  })

  const { run: tourRun, handleJoyrideCallback } = useTour("job_detail")
  const tourSteps = [
    {
      target: "[data-tour='job-timeline']",
      title: tTours("job_detail.timeline_title"),
      content: tTours("job_detail.timeline_content"),
      placement: "right" as const,
    },
    {
      target: "[data-tour='job-approve']",
      title: tTours("job_detail.approve_title"),
      content: tTours("job_detail.approve_content"),
      placement: "bottom" as const,
    },
    {
      target: "[data-tour='job-feedback']",
      title: tTours("job_detail.feedback_title"),
      content: tTours("job_detail.feedback_content"),
      placement: "bottom" as const,
    },
    {
      target: "[data-tour='job-pr-link']",
      title: tTours("job_detail.pr_title"),
      content: tTours("job_detail.pr_content"),
      placement: "bottom" as const,
    },
  ]

  useEffect(() => {
    setNotice(payload.message || null)
  }, [payload.job.id, payload.message])

  useEffect(() => {
    if (activeTab !== "workflows" || !workflowAnchor) return undefined

    const frame = window.requestAnimationFrame(() => {
      document.getElementById(workflowAnchor)?.scrollIntoView({ block: "start" })
    })

    return () => window.cancelAnimationFrame(frame)
  }, [activeTab, workflowAnchor, renderedWorkflowIds])

  return (
    <>
      <SyrusTour onEvent={(data) => handleJoyrideCallback(data)} run={tourRun} steps={tourSteps} />
      <header className="space-y-3">
        <div className="min-w-0">
          <h1 className="break-words text-3xl font-semibold text-gray-900 dark:text-gray-100">
            <CopyableSlug slug={jobSlug(payload.job.id)} />
            <span className="px-2 text-gray-400 dark:text-gray-500">·</span>
            <PendingJobTitle pending={Boolean(payload.job.title_pending)} title={title} />
          </h1>
          <div className="mt-1.5 flex flex-wrap items-center justify-between gap-3">
            <div className="shrink-0"><JobStateBadge state={payload.job.summary_state} /></div>
            <HeaderActions
              command={command}
              feedbackPanelOpen={feedbackPanelOpen}
              onToggleFeedbackPanel={() => setFeedbackPanelOpen((current) => !current)}
              payload={payload}
            />
          </div>
          <div className="flex flex-wrap items-center gap-2">
            <p className="mt-1 break-words text-sm text-gray-600 dark:text-gray-300">
              <Link className="font-mono hover:underline" to={withRoutePrefix(payload.repository.repository_path, prefix)}>{payload.repository.slug}</Link>
              <span className="px-2 text-gray-300 dark:text-gray-600">/</span>
              <JobSourceLink payload={payload} prefix={prefix} />
            </p>
            {payload.job.agent_provider ? <SmallPill>{payload.job.agent_provider}</SmallPill> : null}
            <ProviderAvailabilityWarning availability={payload.job.provider_availability} />
            {payload.job.credential_mode ? <SmallPill>{payload.job.credential_mode}</SmallPill> : null}
          </div>
          <div className="mt-1 flex flex-wrap items-center gap-x-1 gap-y-1 text-sm text-gray-500 dark:text-gray-400">
            <span>{t("workflow_count", { count: payload.job.workflows_count })} · {t("run_count", { count: payload.job.runs_count })}</span>
            {payload.job.total_cost_usd == null ? null : <span>· {formatCurrency(payload.job.total_cost_usd)}</span>}
            {payload.job.prepare_skipped ? <span className="font-medium text-amber-700">· {t("prepare_skipped")}</span> : null}
            {payload.job.source_chat ? (
              <span>
                · <Link className="font-medium text-blue-600 hover:underline dark:text-blue-300" to={withRoutePrefix(payload.job.source_chat.path, prefix)}>{payload.job.source_chat.label}</Link>
              </span>
            ) : null}
            {payload.origin_chat ? (
              <span>
                · <Link className="inline-flex items-center gap-1 font-medium text-blue-600 hover:underline dark:text-blue-300" to={withRoutePrefix(`/chats/${payload.origin_chat.chat_session_id}#message-${payload.origin_chat.message_id}`, prefix)}>
                  <ChatBubbleIcon />
                  <span>{t("view_in_chat")}</span>
                </Link>
              </span>
            ) : null}
          </div>
        </div>
      </header>

      <NoticeToast message={notice} onDismiss={() => setNotice(null)} />
      {command.isError ? <PanelMessage tone="error">{errorMessage(command.error, t("command_error"))}</PanelMessage> : null}
      {command.dialog}
      {payload.job.state === "queued" && payload.repository.landing_paused && payload.repository.main_health === "broken" ? (
        <div className="flex items-center gap-3 rounded border border-amber-200 bg-amber-50 px-4 py-3 text-sm dark:border-amber-900 dark:bg-amber-950/40" role="alert">
          <span className="text-amber-800 dark:text-amber-200">
            {payload.job.main_branch_repair ? t("main_branch_repair_active") : t("main_branch_health_waiting")}
          </span>
          {!payload.job.main_branch_repair ? (
            <Link className="shrink-0 rounded border border-amber-300 bg-white px-2 py-1 text-xs font-medium text-amber-800 hover:bg-amber-50 dark:border-amber-800 dark:bg-amber-950 dark:text-amber-200 dark:hover:bg-amber-900" to={withRoutePrefix(payload.repository.repository_path, prefix)}>
              {t("main_branch_health_view")}
            </Link>
          ) : null}
        </div>
      ) : null}
      {feedbackPanelOpen ? (
        <JobFeedbackPanel
          error={feedback.error}
          isPending={feedback.isPending}
          onCancel={() => setFeedbackPanelOpen(false)}
          onSubmit={(body) => feedback.mutate(body)}
        />
      ) : null}

      <TabNav active={activeTab} attachmentsCount={(payload.attachments ?? []).length} workflowsCount={payload.job.workflows_count} hasTestResults={payload.has_test_results} onSelect={onSelectTab} />

      {activeTab === "summary" ? <SummaryTab command={command} payload={payload} prefix={prefix} queryKey={queryKey} /> : null}
      {activeTab === "workflows" ? <WorkflowsTab command={command} payload={payload} prefix={prefix} /> : null}
      {activeTab === "attachments" ? <AttachmentsTab payload={payload} queryKey={queryKey} onNotice={setNotice} /> : null}
      {activeTab === "source" ? <SourceTab jobId={String(payload.job.id)} coverageInfo={latestWorkflowCoverage(payload.workflows)} /> : null}
      {activeTab === "tests" ? <TestsTab payload={payload} /> : null}
    </>
  )
}

function DeploymentStagePipeline({ stages }: { stages: JobDeploymentStage[] }) {
  return (
    <div aria-label="Deployment stages" className="mt-3 overflow-x-auto pb-1">
      <ol className="flex min-w-max items-start" data-testid="deployment-stage-pipeline">
        {stages.map((stage, index) => {
          const reached = Boolean(stage.reached_at)
          const nextReached = Boolean(stages[index + 1]?.reached_at)
          return (
            <li className="flex items-start" data-reached={reached ? "true" : "false"} key={stage.name}>
              <div className="flex w-36 flex-col items-start gap-1">
                <span className={`inline-flex h-5 w-5 items-center justify-center rounded-full border text-[11px] font-semibold ${reached ? "border-emerald-200 bg-emerald-100 text-emerald-700 dark:border-emerald-800 dark:bg-emerald-950 dark:text-emerald-300" : "border-gray-300 bg-gray-100 text-gray-400 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-500"}`}>
                  {reached ? "✓" : ""}
                </span>
                <span className="max-w-32 break-words text-xs font-medium text-gray-800 dark:text-gray-100">{stage.label}</span>
                <span className={`text-xs ${reached ? "text-emerald-700 dark:text-emerald-300" : "text-gray-400 dark:text-gray-500"}`}>
                  {reached ? <RelativeTimestamp value={stage.reached_at} /> : "Pending"}
                </span>
              </div>
              {index < stages.length - 1 ? (
                <span className="mt-2.5 h-0.5 w-16 shrink-0 overflow-hidden rounded bg-gray-200 dark:bg-gray-800" aria-hidden="true">
                  <span className={`block h-full ${reached && nextReached ? "bg-emerald-500" : "bg-transparent"}`} />
                </span>
              ) : null}
            </li>
          )
        })}
      </ol>
    </div>
  )
}

function TabNav({ active, workflowsCount, attachmentsCount, hasTestResults, onSelect }: { active: JobTab; workflowsCount: number; attachmentsCount: number; hasTestResults: boolean; onSelect: (tab: JobTab) => void }) {
  const { t } = useT("jobs")
  const tabs: Array<{ id: JobTab; label: string }> = [
    { id: "summary", label: t("tab_summary") },
    { id: "workflows", label: t("tab_workflows", { count: workflowsCount }) },
    { id: "attachments", label: t("tab_attachments", { count: attachmentsCount }) },
    { id: "source", label: t("tab_source") }
  ]

  if (hasTestResults) {
    tabs.push({ id: "tests", label: t("tab_tests") })
  }

  return (
    <div className="flex overflow-x-auto border-b border-gray-200 dark:border-gray-700">
      {tabs.map((tab) => (
        <button
          className={`shrink-0 border-b-2 px-4 py-3 text-sm font-medium ${active === tab.id ? "border-blue-600 text-blue-600 dark:border-blue-400 dark:text-blue-300" : "border-transparent text-gray-500 hover:text-gray-800 dark:text-gray-400 dark:hover:text-gray-200"}`}
          key={tab.id}
          onClick={() => onSelect(tab.id)}
          type="button"
        >
          {tab.label}
        </button>
      ))}
    </div>
  )
}

function SummaryTab({ payload, command, prefix, queryKey }: { payload: JobDetailPayload; command: ReturnType<typeof useJobCommand>; prefix: string; queryKey: JobDetailQueryKey }) {
  const { t } = useT("jobs")
  const coverageInfo = latestWorkflowCoverage(payload.workflows)
  return (
    <div className="space-y-4">
      <NeedsAttentionBanner job={payload.job} />
      {payload.merge_train_status ? <JobMergeTrainPanel payload={payload} /> : null}
      {payload.landing_queue_entry ? (
        <PanelMessage>
          {t("landing_queue_position", { position: payload.landing_queue_entry.position })}
          {payload.landing_queue_entry.blocked_reason ? ` (${translateBlockedReason(payload.landing_queue_entry.blocked_reason, t)})` : ""}
          {payload.landing_queue_entry.waiting_for_jobs.length > 0 ? (
            <>
              {" "}
              {t("landing_queue_waiting_for")} {payload.landing_queue_entry.waiting_for_jobs.map((job, index) => (
                <span key={job.id}>
                  {index > 0 ? ", " : null}
                  <Link className="font-medium text-blue-700 underline hover:no-underline" to={`${prefix}${job.job_path}`}>
                    {job.label} {job.title}
                  </Link>
                </span>
              ))}
            </>
          ) : null}
        </PanelMessage>
      ) : null}
      {payload.job.landing_failure_reason ? <PanelMessage tone="error">{t("landing_failed", { reason: payload.job.landing_failure_reason })}</PanelMessage> : null}
      <RetryStatePanel payload={payload} />
      {payload.unsatisfied_dependencies.length > 0 ? <UnsatisfiedDependencies command={command} payload={payload} /> : null}

      <div className="grid gap-4 lg:grid-cols-[62%_38%]">
        <div className="space-y-4">
          <section className="rounded border border-gray-200 bg-white p-4 dark:border-gray-700 dark:bg-gray-900">
            <h2 className="text-sm font-semibold text-gray-900 dark:text-gray-100">{t("section_issue")}</h2>
            {payload.job.issue_body ? <Markdown className="chat-prose mt-2 text-sm text-gray-700 dark:text-gray-300" text={payload.job.issue_body} /> : <p className="mt-2 text-sm text-gray-400 dark:text-gray-500">{t("no_issue_body")}</p>}
          </section>
          <section className="rounded border border-gray-200 bg-white p-4 dark:border-gray-700 dark:bg-gray-900">
            <h2 className="text-sm font-semibold text-gray-900 dark:text-gray-100">{t("section_agent_summary")}</h2>
            {payload.summary ? <Markdown className="chat-prose mt-2 text-sm text-gray-700 dark:text-gray-300" text={payload.summary.text} /> : <p className="mt-2 text-sm text-gray-400 dark:text-gray-500">{t("no_summary")}</p>}
          </section>

          <TestPlanPanel testPlan={payload.test_plan} />

          {coverageInfo ? <CoverageCard coverage={coverageInfo.coverage} /> : null}

          <PendingFeedbackPanel jobId={payload.job.id} comments={payload.pending_feedback} queryKey={queryKey} />

          <FeedbackHistoryPanel prefix={prefix} workflows={payload.workflows} />

          <TimelinePanel canView={payload.actions.can_view_timeline} jobId={payload.job.id} prefix={prefix} runsCount={payload.job.runs_count} />
          <AttachmentPreview attachments={payload.attachments} />
        </div>

        <div className="space-y-4">
          <section className="rounded border border-gray-200 bg-white p-4 text-sm dark:border-gray-700 dark:bg-gray-900" data-tour="job-pr-link">
            <h2 className="font-semibold text-gray-900 dark:text-gray-100">{t("section_details")}</h2>
            {payload.deployment_stages?.length ? <DeploymentStagePipeline stages={payload.deployment_stages} /> : null}
            <div className="mt-3 grid grid-cols-1 gap-x-4 gap-y-3 sm:grid-cols-2">
              <KeyValue label={t("detail_state")}><StatusPill state={payload.job.summary_state} /></KeyValue>
              <KeyValue label={t("detail_owner")}><JobOwnerLabel command={command} payload={payload} prefix={prefix} /></KeyValue>
              <KeyValue label={t("detail_priority")}><PrioritySelector currentPriority={payload.job.priority} priorityPath={payload.paths.app_priority_path} queryKey={queryKey} /></KeyValue>
              <KeyValue label={t("detail_provider")}><JobProviderSelector payload={payload} providerPath={payload.paths.app_provider_setting_path || `/api/v1/app/jobs/${payload.job.id}/provider_setting`} queryKey={queryKey} /></KeyValue>
              <KeyValue label={t("detail_validity")}><span className="capitalize">{payload.job.validity}</span></KeyValue>
              {payload.epic ? <KeyValue label={t("detail_epic")}><EpicSummaryLink epic={payload.epic} prefix={prefix} /></KeyValue> : null}
              {payload.job.branch_name ? <KeyValue label={t("detail_branch")}><code className="break-all">{payload.job.branch_name}</code></KeyValue> : null}
              <KeyValue label={t("detail_stack_base")}><StackBaseForm command={command} payload={payload} /></KeyValue>
              {payload.job.pr_number || payload.job.external_pr_number ? <KeyValue label={t("detail_pull_request")}><PullRequestSummary payload={payload} /></KeyValue> : null}
              {!payload.job.pr_number && !payload.job.external_pr_number && payload.job.no_pr_reason ? <KeyValue label={t("detail_pull_request")}><span className="text-gray-600 dark:text-gray-300">{payload.job.no_pr_reason.message || t("no_pr_opened")}</span></KeyValue> : null}
              <KeyValue label={t("detail_cost")}>{payload.job.total_cost_usd == null ? "-" : formatCurrency(payload.job.total_cost_usd)} <span className="text-xs text-gray-400 dark:text-gray-500">({payload.job.billed_runs_count} {t("detail_billed")})</span></KeyValue>
              <KeyValue label={t("detail_started")}><RelativeTimestamp value={payload.job.started_at} /></KeyValue>
              {payload.job.finished_at ? <KeyValue label={t("detail_closed")}><RelativeTimestamp value={payload.job.finished_at} /> ({payload.job.closure_reason || "unspecified"})</KeyValue> : null}
            </div>
            <TagsPanel canManageTags={payload.actions.can_manage_tags} embedded command={command} payload={payload} />
          </section>

          <ApprovalStatusPanel payload={payload} />
          <DependenciesPanel command={command} payload={payload} />
        </div>
      </div>
    </div>
  )
}

const JOB_PRIORITIES = ["urgent", "high", "medium", "low"] as const

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
      <select
        aria-label={t("detail_priority")}
        className="rounded border border-gray-300 bg-white py-0.5 pl-1.5 pr-6 text-xs text-gray-700 disabled:opacity-50 dark:border-gray-600 dark:bg-gray-900 dark:text-gray-300"
        disabled={mutation.isPending}
        onChange={(e) => handleChange(e.target.value)}
        value={currentPriority}
      >
        {JOB_PRIORITIES.map((p) => (
          <option key={p} value={p}>{labels[p]}</option>
        ))}
      </select>
      {error ? <span className="text-xs text-red-600 dark:text-red-400" role="alert">{error}</span> : null}
      {showConfirm ? <UrgentConfirmDialog onCancel={handleCancel} onConfirm={handleConfirm} /> : null}
    </span>
  )
}

function JobProviderSelector({ payload, providerPath, queryKey }: { payload: JobDetailPayload; providerPath: string; queryKey: JobDetailQueryKey }) {
  const { t } = useT("jobs")
  const queryClient = useQueryClient()
  const [error, setError] = useState<string | null>(null)

  const mutation = useMutation({
    mutationFn: (setting: string) => updateJobProviderSetting(providerPath, setting),
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey })
      void queryClient.invalidateQueries({ queryKey: ["jobs"], exact: true })
      setError(null)
    },
    onError: () => setError(t("provider_setting_update_error"))
  })
  const currentSetting = payload.job.job_provider_setting || "default"
  const options = payload.job.job_provider_setting_options || [
    { value: "default" as const, label: t("provider_setting_default"), configured: true },
    { value: "claude" as const, label: "Claude Code", configured: true },
    { value: "codex" as const, label: "Codex", configured: true }
  ]

  return (
    <span className="inline-flex max-w-full flex-col gap-1">
      <select
        aria-describedby={`job-${payload.job.id}-provider-help`}
        aria-label={t("detail_provider")}
        className="max-w-full rounded border border-gray-300 bg-white py-0.5 pl-1.5 pr-6 text-xs text-gray-700 disabled:opacity-50 dark:border-gray-600 dark:bg-gray-900 dark:text-gray-300"
        disabled={mutation.isPending}
        onChange={(event) => mutation.mutate(event.target.value)}
        value={currentSetting}
      >
        {options.map((option) => (
          <option disabled={!option.configured} key={option.value} value={option.value}>
            {option.value === "default" ? t("provider_setting_default") : option.label}
          </option>
        ))}
      </select>
      <span className="text-xs text-gray-500 dark:text-gray-400" id={`job-${payload.job.id}-provider-help`}>
        {t("provider_setting_help", { provider: agentProviderLabel(payload.job.agent_provider || "") })}
      </span>
      {error ? <span className="text-xs text-red-600 dark:text-red-400" role="alert">{error}</span> : null}
    </span>
  )
}

function agentProviderLabel(provider: string) {
  if (provider === "codex") return "Codex"
  if (provider === "claude") return "Claude Code"
  return provider || "default"
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
    <div
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4"
      onClick={onCancel}
    >
      <section
        aria-labelledby="urgent-confirm-title"
        aria-modal="true"
        className="w-full max-w-md rounded-lg bg-white shadow-xl dark:bg-gray-900"
        role="dialog"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="space-y-4 p-5">
          <h2 className="text-base font-semibold text-gray-900 dark:text-gray-100" id="urgent-confirm-title">
            {t("priority_urgent_confirm_title")}
          </h2>
          <p className="text-sm text-gray-700 dark:text-gray-300">{t("priority_urgent_confirm_body_1")}</p>
          <p className="text-sm text-gray-700 dark:text-gray-300">{t("priority_urgent_confirm_body_2")}</p>
          <div className="flex justify-end gap-3">
            <button
              className="rounded border border-gray-300 px-4 py-1.5 text-sm text-gray-700 hover:bg-gray-50 dark:border-gray-600 dark:text-gray-300 dark:hover:bg-gray-800"
              onClick={onCancel}
              type="button"
            >
              {t("priority_cancel")}
            </button>
            <button
              className="rounded bg-red-600 px-4 py-1.5 text-sm font-medium text-white hover:bg-red-700"
              onClick={onConfirm}
              type="button"
            >
              {t("priority_urgent_confirm_button")}
            </button>
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
    <section className="rounded border border-gray-200 bg-white p-4 dark:border-gray-700 dark:bg-gray-900">
      <h2 className="text-sm font-semibold text-gray-900 dark:text-gray-100">{t("section_test_plan")}</h2>
      <ol className="mt-2 list-decimal space-y-1 pl-5 text-sm text-gray-700 dark:text-gray-300">
        {testPlan.steps.map((step, index) => <li key={`${index}-${step}`}>{step}</li>)}
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
      <p className="mt-1 text-xs text-amber-700 dark:text-amber-400">
        {t("pending_feedback_description")}
      </p>
      {notice ? (
        <div className="mt-2 flex items-center justify-between gap-2 rounded bg-amber-100 px-3 py-2 text-xs text-amber-800 dark:bg-amber-900/40 dark:text-amber-300">
          <span>{notice}</span>
          <button className="ml-2 hover:underline" onClick={() => setNotice(null)} type="button">{t("dismiss")}</button>
        </div>
      ) : null}
      {(apply.isError || ignore.isError || replace.isError || retry.isError) ? (
        <p className="mt-2 text-xs text-red-600 dark:text-red-400">
          {apply.error instanceof Error ? apply.error.message : ignore.error instanceof Error ? ignore.error.message : replace.error instanceof Error ? replace.error.message : retry.error instanceof Error ? retry.error.message : "Action failed."}
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
              {comment.comment_created_at ? <span>· <RelativeTimestamp value={comment.comment_created_at} /></span> : null}
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
                  className="block w-full rounded border border-gray-300 bg-white px-3 py-2 text-sm focus:outline-blue-600 dark:border-gray-600 dark:bg-gray-800 dark:text-gray-200"
                  onChange={(e) => setReplaceBody(e.target.value)}
                  placeholder={t("replacement_feedback_placeholder")}
                  rows={3}
                  value={replaceBody}
                />
                <div className="flex gap-2">
                  <button
                    className="rounded bg-blue-600 px-3 py-1.5 text-xs font-medium text-white hover:bg-blue-500 disabled:cursor-not-allowed disabled:opacity-50"
                    disabled={isPending || !replaceBody.trim()}
                    onClick={() => replace.mutate({ commentId: comment.id, body: replaceBody })}
                    type="button"
                  >
                    Submit replacement
                  </button>
                  <button
                    className="text-xs text-gray-500 hover:underline dark:text-gray-400"
                    onClick={() => { setReplaceId(null); setReplaceBody("") }}
                    type="button"
                  >
                    Cancel
                  </button>
                </div>
              </div>
            ) : (
              <div className="mt-3 flex flex-wrap gap-2">
                {comment.retryable ? (
                  <button
                    className="rounded bg-blue-600 px-3 py-1.5 text-xs font-medium text-white hover:bg-blue-500 disabled:cursor-not-allowed disabled:opacity-50"
                    disabled={isPending}
                    onClick={() => retry.mutate(comment.id)}
                    type="button"
                  >
                    {t("pending_feedback_retry")}
                  </button>
                ) : (
                  <>
                    <button
                      className="rounded bg-blue-600 px-3 py-1.5 text-xs font-medium text-white hover:bg-blue-500 disabled:cursor-not-allowed disabled:opacity-50"
                      disabled={isPending}
                      onClick={() => apply.mutate(comment.id)}
                      type="button"
                    >
                      Apply
                    </button>
                    <button
                      className="rounded border border-gray-300 px-3 py-1.5 text-xs font-medium text-gray-700 hover:bg-gray-50 disabled:cursor-not-allowed disabled:opacity-50 dark:border-gray-600 dark:text-gray-300 dark:hover:bg-gray-800"
                      disabled={isPending}
                      onClick={() => { setReplaceId(comment.id); setReplaceBody("") }}
                      type="button"
                    >
                      Replace
                    </button>
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

export function FeedbackHistoryPanel({ workflows, prefix }: { workflows: JobWorkflow[]; prefix: string }) {
  const { t } = useT("jobs")
  const feedbackWorkflows = [...workflows]
    .filter((workflow) => workflow.trigger_kind === "chat_feedback" || workflow.trigger_kind === "pr_comment")
    .sort((left, right) => workflowCreatedAtTime(right) - workflowCreatedAtTime(left))

  if (feedbackWorkflows.length === 0) return null

  return (
    <section className="rounded border border-gray-200 bg-white p-4 dark:border-gray-700 dark:bg-gray-900">
      <h2 className="text-sm font-semibold text-gray-900 dark:text-gray-100">{t("section_feedback_history")}</h2>
      <div className="mt-3">
        {feedbackWorkflows.map((workflow) => {
          const artifacts = workflow.artifacts ?? {}
          const chatFeedback = artifacts.chat_feedback
          return (
            <div className="mt-3 border-t border-gray-100 pt-3 first:mt-0 first:border-t-0 first:pt-0 dark:border-gray-800" key={workflow.id}>
              <div className="flex flex-wrap items-center justify-between gap-2">
                <div className="flex flex-wrap items-center gap-2">
                  <span className="text-sm font-medium text-gray-900 dark:text-gray-100">{feedbackTriggerLabel(workflow.trigger_kind, t)}</span>
                  <StatusPill state={workflow.state} />
                </div>
                <div className="flex flex-wrap items-center gap-2 text-xs text-gray-500 dark:text-gray-400">
                  <span><RelativeTimestamp value={workflow.created_at} /></span>
                  <Link className="text-blue-600 hover:underline dark:text-blue-300" to={withRoutePrefix(workflow.path, prefix)}>
                    {workflow.slug || workflowSlug(workflow.id)}
                  </Link>
                </div>
              </div>
              {workflow.trigger_kind === "chat_feedback" ? (
                <>
                  <FeedbackSourceBadge source={artifacts.feedback_source} />
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

function feedbackTriggerLabel(triggerKind: string, t: ReturnType<typeof useT>["t"]) {
  if (triggerKind === "chat_feedback") return t("feedback_trigger_chat")
  if (triggerKind === "pr_comment") return t("feedback_trigger_pr")
  return triggerKind.replaceAll("_", " ")
}

function JobMergeTrainPanel({ payload }: { payload: JobDetailPayload }) {
  const { t } = useT("jobs")
  const status = payload.merge_train_status
  if (!status) return null

  const tone = status.phase === "failed"
    ? "border-red-200 bg-red-50 text-red-800 dark:border-red-900/70 dark:bg-red-950/40 dark:text-red-200"
    : "border-teal-200 bg-teal-50 text-teal-900 dark:border-teal-900/70 dark:bg-teal-950/40 dark:text-teal-100"
  return (
    <section className={`rounded border px-4 py-3 text-sm ${tone}`}>
      <span className="block font-medium">
        {t(`merge_train_phase.${status.phase}`, { defaultValue: status.phase })}
        {payload.epic ? ` · ${payload.epic.display_number}` : ""}
      </span>
      <span className="mt-1 block">{jobMergeTrainDetail(status, t)}</span>
      {status.branch ? <code className="mt-1 block break-all font-mono text-xs">{status.branch}</code> : null}
    </section>
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

function RetryStatePanel({ payload }: { payload: JobDetailPayload }) {
  const { t } = useT("jobs")
  const retry = payload.job.retry_state
  if (!retry || (retry.state_label === "No failure" && !retry.classification)) return null

  return (
    <section className={`rounded border px-4 py-3 text-sm ${retry.auto_retry_exhausted ? "border-red-200 bg-red-50 text-red-800 dark:border-red-900/70 dark:bg-red-950/40 dark:text-red-200" : retry.provider_circuit_open ? "border-amber-200 bg-amber-50 text-amber-900 dark:border-amber-900/70 dark:bg-amber-950/40 dark:text-amber-200" : "border-gray-200 bg-white text-gray-700 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-300"}`}>
      <div className="flex flex-wrap items-center gap-2">
        <span className="font-semibold">{retry.state_label}</span>
        <SmallPill>{retry.classification_label}</SmallPill>
        <SmallPill>{retry.retryable ? t("run_retryable") : t("run_not_retryable")}</SmallPill>
        <SmallPill>{retry.retry_attempt_count}/{retry.retry_budget} {t("retry_attempts_label")}</SmallPill>
        <SmallPill>{retry.retry_budget_remaining} {t("retry_remaining_label")}</SmallPill>
      </div>
      <div className="mt-1 flex flex-wrap gap-x-4 gap-y-1 text-xs">
        {retry.next_auto_retry_at ? <span>{t("retry_state_next_retry")} <RelativeTimestamp value={retry.next_auto_retry_at} /></span> : null}
        {retry.retry_delayed_until ? <span>{t("retry_state_delayed_until")} <RelativeTimestamp value={retry.retry_delayed_until} /></span> : null}
        {retry.retry_delay_reason ? <span>{retry.retry_delay_reason}</span> : null}
      </div>
    </section>
  )
}

function JobOwnerLabel({ payload, command, prefix }: { payload: JobDetailPayload; command: ReturnType<typeof useJobCommand>; prefix: string }) {
  const { t } = useT("jobs")
  const owner = payload.job.claimed_by_user

  return (
    <span className="inline-flex flex-wrap items-center gap-2">
      {owner ? (
        <>
          <Link className="font-medium text-blue-700 hover:underline" to={withRoutePrefix(owner.profile_path, prefix)}>
            {payload.job.claimed_by_current_user ? t("owner_you") : owner.display_name}
          </Link>
          {payload.job.claimed_at ? <span className="text-xs text-gray-400 dark:text-gray-500"><RelativeTimestamp value={payload.job.claimed_at} /></span> : null}
        </>
      ) : (
        <span className="text-gray-400 dark:text-gray-500">{t("owner_unclaimed")}</span>
      )}
      {payload.actions.can_claim ? (
        <button className="text-xs font-medium text-blue-600 hover:underline disabled:cursor-not-allowed disabled:opacity-50" disabled={command.isPending} onClick={() => command.mutate({ method: "post", path: payload.paths.app_claim_path })} type="button">{t("owner_claim")}</button>
      ) : null}
      {payload.actions.can_unclaim ? (
        <button className="text-xs text-gray-500 hover:underline disabled:cursor-not-allowed disabled:opacity-50 dark:text-gray-400" disabled={command.isPending} onClick={() => command.mutate({ method: "delete", path: payload.paths.app_claim_path })} type="button">{t("owner_release")}</button>
      ) : null}
    </span>
  )
}

function UnsatisfiedDependencies({ payload, command }: { payload: JobDetailPayload; command: ReturnType<typeof useJobCommand> }) {
  const { t } = useT("jobs")
  const count = payload.unsatisfied_dependencies.length
  return (
    <section className="rounded border border-amber-200 bg-amber-50 px-4 py-3 text-sm text-amber-900 dark:border-amber-900/70 dark:bg-amber-950/40 dark:text-amber-200">
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
          <CommandButton command={command} input={{ method: "post", path: payload.paths.app_dependency_override_path, confirm: t("confirm_override_dependencies") }} tone="danger-outline">
            {t("override_and_force_run")}
          </CommandButton>
        ) : null}
      </div>
    </section>
  )
}

function StackBaseForm({ payload, command }: { payload: JobDetailPayload; command: ReturnType<typeof useJobCommand> }) {
  const { t } = useT("jobs")
  const [stackBase, setStackBase] = useState(payload.job.stack_base)

  useEffect(() => setStackBase(payload.job.stack_base), [payload.job.stack_base])

  return (
    <form className="flex flex-wrap items-center gap-2" onSubmit={(event) => {
      event.preventDefault()
      command.mutate({ method: "patch", path: payload.paths.app_stack_base_path, body: { stack_base: stackBase } })
    }}>
      <select className="rounded border border-gray-300 bg-white px-2 py-1 text-xs text-gray-900 dark:border-gray-700 dark:bg-gray-950 dark:text-gray-100" onChange={(event) => setStackBase(event.target.value)} value={stackBase}>
        <option value="auto">auto</option>
        <option value="main">main</option>
      </select>
      <button className="text-xs text-blue-600 hover:underline" disabled={command.isPending} type="submit">{t("stack_base_update")}</button>
    </form>
  )
}

function PullRequestSummary({ payload }: { payload: JobDetailPayload }) {
  const { t } = useT("jobs")
  if (!payload.job.pr_number && !payload.job.external_pr_number) return <span className="text-gray-400 dark:text-gray-500">-</span>

  return (
    <div className="space-y-1">
      {payload.job.pr_number ? <a className="text-blue-600 hover:underline" href={payload.job.pr_url || "#"} rel="noopener" target="_blank">{t("pr_syrus", { number: payload.job.pr_number })}</a> : null}
      {payload.job.external_pr_number ? <a className="block text-violet-700 hover:underline" href={payload.job.external_pr_url || "#"} rel="noopener" target="_blank">{t("pr_external", { number: payload.job.external_pr_number })}</a> : null}
      <div><MergeablePill value={payload.job.pr_mergeable} /> {payload.job.pr_mergeable_checked_at ? <span className="text-xs text-gray-400 dark:text-gray-500">{t("pr_checked")} <RelativeTimestamp value={payload.job.pr_mergeable_checked_at} /></span> : null}</div>
    </div>
  )
}

function ApprovalStatusPanel({ payload }: { payload: JobDetailPayload }) {
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
      <h2 className="font-semibold text-gray-900 dark:text-gray-100">{t("section_approval")}</h2>
      <div className="mt-2 space-y-2">
        <div className="flex items-center justify-between">
          <span className="text-gray-500 dark:text-gray-400">{t("approval_policy")}</span>
          <span className="text-gray-700 dark:text-gray-300">{policyLabel[repository.review_policy] ?? repository.review_policy}</span>
        </div>
        {status && (
          <div className="flex items-center justify-between">
            <span className="text-gray-500 dark:text-gray-400">{t("approval_status")}</span>
            {status.satisfied
              ? <span className="font-medium text-emerald-600 dark:text-emerald-400">{t("approval_satisfied")}</span>
              : <span className="text-amber-600 dark:text-amber-400">{status.pending_description ?? t("approval_pending")}</span>
            }
          </div>
        )}
        {approvals.length > 0 ? (
          <div>
            <span className="text-gray-500 dark:text-gray-400">{t("approval_approvals")}</span>
            <ul className="mt-1 divide-y divide-gray-100 dark:divide-gray-800">
              {approvals.map((approval) => (
                <li key={approval.id} className="flex items-center justify-between py-1 text-xs">
                  <span className="truncate text-gray-700 dark:text-gray-300">{approval.user_email}</span>
                  <span className="ml-2 shrink-0 text-gray-400 dark:text-gray-500"><RelativeTimestamp value={approval.approved_at} /></span>
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

function DependenciesPanel({ payload, command }: { payload: JobDetailPayload; command: ReturnType<typeof useJobCommand> }) {
  const { t } = useT("jobs")
  const [query, setQuery] = useState("")
  const [addingDependency, setAddingDependency] = useState(false)
  const [epicQuery, setEpicQuery] = useState("")
  const [addingEpicDependency, setAddingEpicDependency] = useState(false)
  const dependencyOptions = useQuery({
    queryKey: ["job", payload.job.id, "dependency_options"],
    queryFn: () => fetchJobDependencyOptions(payload.paths.app_dependency_options_path || `${payload.paths.app_dependencies_path.replace(/\/dependencies$/, "")}/dependency_options`),
    enabled: addingDependency || addingEpicDependency,
    staleTime: 30000
  })
  const jobDependencyOptions = dependencyOptions.data?.dependency_target_options ?? payload.dependency_target_options
  const epicDependencyOptions = dependencyOptions.data?.epic_dependency_target_options ?? payload.epic_dependency_target_options

  const trimmedQuery = query.trim()
  const filteredOptions = trimmedQuery.length > 0
    ? jobDependencyOptions.filter((option) => option.label.toLowerCase().includes(trimmedQuery.toLowerCase()))
    : jobDependencyOptions

  const trimmedEpicQuery = epicQuery.trim()
  const filteredEpicOptions = trimmedEpicQuery.length > 0
    ? epicDependencyOptions.filter((option) => option.label.toLowerCase().includes(trimmedEpicQuery.toLowerCase()))
    : epicDependencyOptions

  function choose(value: string) {
    command.mutate({ method: "post", path: payload.paths.app_dependencies_path, body: { dependency_target: value } }, { onSuccess: () => {
      setQuery("")
      setAddingDependency(false)
    }})
  }

  function chooseEpic(epicId: number) {
    command.mutate({ method: "post", path: payload.paths.app_epic_dependencies_path, body: { depends_on_epic_id: epicId } }, { onSuccess: () => {
      setEpicQuery("")
      setAddingEpicDependency(false)
    }})
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
        <h2 className="font-semibold text-gray-900 dark:text-gray-100">{t("section_dependencies")}</h2>
        {payload.dependencies.length > 0 ? (
          <ul className="mt-2 divide-y divide-gray-100 dark:divide-gray-800">
            {payload.dependencies.map((dependency) => {
              const epicTarget = dependency.depends_on_epic
              return (
                <li className="flex flex-wrap items-center justify-between gap-2 py-2" key={dependency.id}>
                  <span className="flex flex-wrap items-center gap-2">
                    <span><DependencyLink dependency={dependency} /> <span className="text-xs text-gray-400 dark:text-gray-500">({dependency.source})</span></span>
                    {!dependency.succeeded ? (
                      <TonePill tone="amber">{t("dependency_not_yet_satisfied")}</TonePill>
                    ) : null}
                  </span>
                  {dependency.manual && !epicTarget ? <button className="text-xs text-red-600 hover:underline" disabled={command.isPending} onClick={() => command.mutate({ method: "delete", path: `${payload.paths.app_dependencies_path}/${dependency.id}`, confirm: t("confirm_remove_dependency") })} type="button">{t("remove_dependency")}</button> : null}
                  {dependency.manual && epicTarget ? <button className="text-xs text-red-600 hover:underline" disabled={command.isPending} onClick={() => command.mutate({ method: "delete", path: `${payload.paths.app_epic_dependencies_path}/${epicTarget.id}`, confirm: t("confirm_remove_epic_dependency", { slug: epicTarget.slug }) })} type="button">{t("remove_dependency")}</button> : null}
                </li>
              )
            })}
          </ul>
        ) : <p className="mt-2 text-gray-400 dark:text-gray-500">{t("section_no_dependencies")}</p>}
        {addingDependency ? (
          <div className="mt-3 border-t border-gray-100 pt-3 dark:border-gray-800">
            <label className="block text-xs font-medium uppercase text-gray-500 dark:text-gray-400">
              {t("dependency_search_label")}
              <div className="relative mt-1">
                <input
                  aria-autocomplete="list"
                  autoFocus
                  className="w-full rounded border border-gray-300 bg-white px-2 py-1.5 text-sm normal-case text-gray-700 dark:border-gray-700 dark:bg-gray-950 dark:text-gray-100"
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
                  <div className="absolute left-0 right-0 top-full z-20 mt-1 rounded border border-gray-200 bg-white px-3 py-1.5 text-sm text-gray-400 shadow-lg dark:border-gray-700 dark:bg-gray-900 dark:text-gray-500">{t("dependency_no_matches")}</div>
                ) : null}
              </div>
            </label>
            <button className="mt-2 text-xs text-gray-500 hover:underline disabled:cursor-not-allowed disabled:opacity-50" disabled={command.isPending} onClick={cancelAdding} type="button">{t("cancel")}</button>
          </div>
        ) : addingEpicDependency ? (
          <div className="mt-3 border-t border-gray-100 pt-3 dark:border-gray-800">
            <label className="block text-xs font-medium uppercase text-gray-500 dark:text-gray-400">
              {t("epic_dependency_search_label")}
              <div className="relative mt-1">
                <input
                  aria-autocomplete="list"
                  autoFocus
                  className="w-full rounded border border-gray-300 bg-white px-2 py-1.5 text-sm normal-case text-gray-700 dark:border-gray-700 dark:bg-gray-950 dark:text-gray-100"
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
                  <div className="absolute left-0 right-0 top-full z-20 mt-1 rounded border border-gray-200 bg-white px-3 py-1.5 text-sm text-gray-400 shadow-lg dark:border-gray-700 dark:bg-gray-900 dark:text-gray-500">{t("epic_dependency_no_matches")}</div>
                ) : null}
              </div>
            </label>
            <button className="mt-2 text-xs text-gray-500 hover:underline disabled:cursor-not-allowed disabled:opacity-50" disabled={command.isPending} onClick={cancelAddingEpic} type="button">{t("cancel")}</button>
          </div>
        ) : (
          <div className="mt-3 flex flex-wrap gap-3 border-t border-gray-100 pt-3 dark:border-gray-800">
            <button className="text-xs font-medium text-blue-600 hover:underline" onClick={() => setAddingDependency(true)} type="button">{t("add_dependency")}</button>
            {epicDependencyOptions.length > 0 || !dependencyOptions.isSuccess ? (
              <button className="text-xs font-medium text-blue-600 hover:underline" onClick={() => setAddingEpicDependency(true)} type="button">{t("add_epic_dependency")}</button>
            ) : null}
          </div>
        )}
      </div>
      {payload.dependents.length > 0 ? (
        <div className="rounded border border-gray-200 bg-white p-4 text-sm dark:border-gray-700 dark:bg-gray-900">
          <h2 className="font-semibold text-gray-900 dark:text-gray-100">{t("dependents_title", { count: payload.dependents.length })}</h2>
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

function formatTestDuration(ms: number): string {
  if (ms < 1000) return `${ms}ms`
  if (ms < 60000) return `${(ms / 1000).toFixed(2)}s`
  const minutes = Math.floor(ms / 60000)
  const seconds = Math.round((ms % 60000) / 1000)
  return `${minutes}m ${seconds}s`
}

function TestStatusIcon({ status }: { status: JobTestCase["status"] }) {
  if (status === "passed") return <span aria-hidden="true" className="text-emerald-600 dark:text-emerald-400">✓</span>
  if (status === "failed" || status === "error") return <span aria-hidden="true" className="text-red-600 dark:text-red-400">✗</span>
  return <span aria-hidden="true" className="text-gray-400 dark:text-gray-500">−</span>
}

function FlakinessSparkline({ statuses }: { statuses: Array<"passed" | "failed" | "skipped" | "error"> }) {
  return (
    <span aria-hidden="true" className="inline-flex items-center gap-0.5">
      {statuses.map((s, i) => (
        <span
          key={i}
          className={`inline-block h-2 w-2 rounded-sm ${
            s === "passed"
              ? "bg-emerald-400 dark:bg-emerald-500"
              : s === "failed" || s === "error"
                ? "bg-red-400 dark:bg-red-500"
                : "bg-gray-300 dark:bg-gray-600"
          }`}
        />
      ))}
    </span>
  )
}

function FlakinessBadge({ testCase }: { testCase: JobTestCase }) {
  const { t } = useT("jobs")
  const score = testCase.flakiness_score
  const failed = testCase.flakiness_failed_count
  const total = testCase.flakiness_total_count
  const statuses = testCase.flakiness_run_statuses

  if (score == null || score <= 0 || score >= 1.0 || failed == null || total == null) return null

  return (
    <span
      className="inline-flex shrink-0 items-center gap-1 rounded border border-amber-300 bg-amber-50 px-1.5 py-0.5 text-xs font-medium text-amber-700 dark:border-amber-700 dark:bg-amber-950 dark:text-amber-300"
      title={t("tests_flaky_tooltip", { failed, total })}
    >
      {t("tests_flaky_label")}
      <span className="font-normal opacity-75">{failed}/{total}</span>
      {statuses && statuses.length > 1 ? <FlakinessSparkline statuses={statuses} /> : null}
    </span>
  )
}

function TestCaseRow({ testCase }: { testCase: JobTestCase }) {
  const { t } = useT("jobs")
  const [expanded, setExpanded] = useState(false)
  const hasDetail = (testCase.failure_message || testCase.failure_backtrace || testCase.output) && (testCase.status === "failed" || testCase.status === "error")

  return (
    <div>
      <div
        className={`flex items-start gap-2 px-4 py-2 text-sm ${testCase.status === "skipped" ? "text-gray-400 dark:text-gray-500" : "text-gray-800 dark:text-gray-200"}`}
      >
        <span className="mt-0.5 shrink-0 font-mono text-xs"><TestStatusIcon status={testCase.status} /></span>
        <span className="min-w-0 flex-1 break-words">{testCase.name}</span>
        <FlakinessBadge testCase={testCase} />
        {testCase.duration_ms != null ? (
          <span className="shrink-0 text-xs text-gray-400 dark:text-gray-500">{formatTestDuration(testCase.duration_ms)}</span>
        ) : null}
        {hasDetail ? (
          <button
            aria-expanded={expanded}
            className="shrink-0 text-xs text-blue-600 hover:underline dark:text-blue-400"
            onClick={() => setExpanded((v) => !v)}
            type="button"
          >
            {expanded ? t("tests_hide_detail") : t("tests_show_detail")}
          </button>
        ) : null}
      </div>
      {expanded && hasDetail ? (
        <div className="mx-4 mb-2 space-y-2 rounded bg-gray-50 p-3 text-xs dark:bg-gray-800">
          {testCase.failure_message ? (
            <div>
              <p className="font-medium text-gray-700 dark:text-gray-300">{t("tests_failure_message")}</p>
              <pre className="mt-1 whitespace-pre-wrap break-words font-mono text-red-700 dark:text-red-400">{testCase.failure_message}</pre>
            </div>
          ) : null}
          {testCase.failure_backtrace ? (
            <div>
              <p className="font-medium text-gray-700 dark:text-gray-300">{t("tests_failure_backtrace")}</p>
              <pre className="mt-1 whitespace-pre-wrap break-words font-mono text-gray-600 dark:text-gray-400">{testCase.failure_backtrace}</pre>
            </div>
          ) : null}
          {testCase.output ? (
            <div>
              <p className="font-medium text-gray-700 dark:text-gray-300">{t("tests_output")}</p>
              <pre className="mt-1 whitespace-pre-wrap break-words font-mono text-gray-600 dark:text-gray-400">{testCase.output}</pre>
            </div>
          ) : null}
        </div>
      ) : null}
    </div>
  )
}

function SuiteGroup({ suite }: { suite: JobTestSuite }) {
  const { t } = useT("jobs")
  const hasFailures = suite.failed_count > 0 || suite.error_count > 0
  const [expanded, setExpanded] = useState(hasFailures)
  const [showSkipped, setShowSkipped] = useState(false)

  const nonSkipped = suite.test_cases.filter((tc) => tc.status !== "skipped")
  const skipped = suite.test_cases.filter((tc) => tc.status === "skipped")

  return (
    <div className="border-t border-gray-100 first:border-t-0 dark:border-gray-800">
      <button
        aria-expanded={expanded}
        className="flex w-full items-center justify-between px-4 py-2 text-left text-sm hover:bg-gray-50 dark:hover:bg-gray-800/50"
        onClick={() => setExpanded((v) => !v)}
        type="button"
      >
        <span className="font-medium text-gray-800 dark:text-gray-200">{suite.suite_name}</span>
        <span className="flex items-center gap-3 text-xs">
          {suite.failed_count > 0 ? <span className="text-red-600 dark:text-red-400">{suite.failed_count} failed</span> : null}
          {suite.error_count > 0 ? <span className="text-red-600 dark:text-red-400">{suite.error_count} error</span> : null}
          {suite.passed_count > 0 ? <span className="text-emerald-600 dark:text-emerald-400">{suite.passed_count} passed</span> : null}
          {suite.skipped_count > 0 ? <span className="text-gray-400 dark:text-gray-500">{suite.skipped_count} skipped</span> : null}
          <span className={`transition-transform ${expanded ? "rotate-90" : ""} text-gray-400 dark:text-gray-500`}>›</span>
        </span>
      </button>
      {expanded ? (
        <div className="divide-y divide-gray-50 dark:divide-gray-800/50">
          {nonSkipped.map((tc) => <TestCaseRow key={tc.id} testCase={tc} />)}
          {skipped.length > 0 ? (
            <div>
              <button
                className="px-4 py-1.5 text-xs text-gray-400 hover:underline dark:text-gray-500"
                onClick={() => setShowSkipped((v) => !v)}
                type="button"
              >
                {showSkipped ? t("tests_hide_skipped") : `${t("tests_show_skipped")} (${skipped.length})`}
              </button>
              {showSkipped ? skipped.map((tc) => <TestCaseRow key={tc.id} testCase={tc} />) : null}
            </div>
          ) : null}
        </div>
      ) : null}
    </div>
  )
}

function TestRunSection({ testRun }: { testRun: JobTestRun }) {
  const { t } = useT("jobs")
  const allPassing = testRun.failed_count === 0 && testRun.error_count === 0

  return (
    <section className="rounded border border-gray-200 bg-white dark:border-gray-700 dark:bg-gray-900">
      <div className="flex flex-wrap items-center justify-between gap-3 p-4">
        <h2 className="text-sm font-semibold text-gray-900 dark:text-gray-100">{testRun.grader_name}</h2>
        <div className="flex flex-wrap items-center gap-3 text-xs">
          <span className="text-emerald-600 dark:text-emerald-400">{testRun.passed_count} passed</span>
          {testRun.failed_count > 0 ? <span className="font-medium text-red-600 dark:text-red-400">{testRun.failed_count} failed</span> : null}
          {testRun.error_count > 0 ? <span className="font-medium text-red-600 dark:text-red-400">{testRun.error_count} error</span> : null}
          {testRun.skipped_count > 0 ? <span className="text-gray-400 dark:text-gray-500">{testRun.skipped_count} skipped</span> : null}
          {testRun.duration_ms != null ? <span className="text-gray-400 dark:text-gray-500">{formatTestDuration(testRun.duration_ms)}</span> : null}
          <span className="text-gray-400 dark:text-gray-500">{testRun.total_count} total</span>
        </div>
      </div>
      {allPassing ? (
        <p className="border-t border-gray-100 px-4 py-3 text-sm text-emerald-600 dark:border-gray-800 dark:text-emerald-400">{t("tests_all_passing")}</p>
      ) : (
        <div className="border-t border-gray-100 dark:border-gray-800">
          {testRun.suites.map((suite) => <SuiteGroup key={suite.suite_name} suite={suite} />)}
        </div>
      )}
    </section>
  )
}

function TestsTab({ payload }: { payload: JobDetailPayload }) {
  const { t } = useT("jobs")
  const { data, isPending, isError } = useQuery({
    queryKey: ["jobs", String(payload.job.id), "test_results"],
    queryFn: () => fetchJobTestResults(payload.paths.app_test_results_path),
    enabled: payload.has_test_results
  })

  if (isPending) return <PanelMessage>{t("loading")}</PanelMessage>
  if (isError) return <PanelMessage tone="error">{t("tests_load_error")}</PanelMessage>
  if (!data || data.test_runs.length === 0) return <PanelMessage>{t("tests_empty")}</PanelMessage>

  return (
    <div className="space-y-4">
      {data.test_runs.map((testRun) => <TestRunSection key={testRun.id} testRun={testRun} />)}
    </div>
  )
}

function AttachmentsTab({ payload, queryKey, onNotice }: { payload: JobDetailPayload; queryKey: JobDetailQueryKey; onNotice: (message: string | null) => void }) {
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
        <h2 className="text-sm font-semibold text-gray-900 dark:text-gray-100">{t("attachment_add_title")}</h2>
        <div className="mt-3 grid gap-3 md:grid-cols-[minmax(0,1fr)_minmax(0,1fr)_auto] md:items-end">
          <label className="text-sm font-medium text-gray-700 dark:text-gray-300">
            {t("attachment_files_label")}
            <input className="mt-1 block w-full text-sm" multiple onChange={(event) => setFiles(Array.from(event.target.files || []))} type="file" />
          </label>
          <label className="text-sm font-medium text-gray-700 dark:text-gray-300">
            {t("attachment_google_doc_label")}
            <input className="mt-1 w-full rounded border border-gray-300 bg-white px-2 py-1.5 text-sm text-gray-900 dark:border-gray-700 dark:bg-gray-950 dark:text-gray-100" onChange={(event) => setGoogleDocUrl(event.target.value)} placeholder={t("attachment_google_doc_placeholder")} type="url" value={googleDocUrl} />
          </label>
          <button className={buttonClass("primary")} disabled={add.isPending || (files.length === 0 && googleDocUrl.trim() === "")} type="submit">{t("attachment_add_button")}</button>
        </div>
        {add.isError ? <p className="mt-2 text-sm text-red-700">{errorMessage(add.error, t("attachment_add_error"))}</p> : null}
      </form>

      {payload.attachments.length > 0 ? (
        <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
          {payload.attachments.map((attachment) => (
            <div className="relative" key={attachment.id}>
              <AttachmentCard attachment={attachment} />
              <button className="absolute right-2 top-2 rounded border border-red-200 bg-white px-2 py-1 text-xs text-red-700 hover:bg-red-50 dark:border-red-900 dark:bg-gray-950 dark:text-red-300 dark:hover:bg-red-950/40" disabled={remove.isPending} onClick={() => remove.mutate(attachment.app_delete_path)} type="button">{t("attachment_remove")}</button>
            </div>
          ))}
        </div>
      ) : <PanelMessage>{t("section_no_attachments")}</PanelMessage>}
      {remove.isError ? <PanelMessage tone="error">{errorMessage(remove.error, t("attachment_remove_error"))}</PanelMessage> : null}
    </section>
  )
}
