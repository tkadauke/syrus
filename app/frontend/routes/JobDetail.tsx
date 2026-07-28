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
import { StatusPill } from "../components/StatusPill"
import { Markdown } from "../lib/Markdown"
import { translateBlockedReason } from "../lib/translateBlockedReason"
import { workflowSlug } from "../lib/slugs"
import { buttonClass } from "../lib/buttonClasses"
import { applyPendingFeedback, createJobAttachments, deleteJobCommand, fetchJobDetail, fetchJobWorkflows, ignorePendingFeedback, replacePendingFeedback, submitJobFeedback, updateJobPriority, type JobApprovalRecord, type JobApprovalStatus, type JobDetailPayload, type JobTestPlan, type JobWorkflow, type PendingFeedbackComment } from "../api/jobs"
import { CoverageCard } from "../components/CoverageCard"
import { errorMessage } from "../lib/errorMessage"
import type { JobDetailQueryKey, JobTab, JobWorkflowsQueryKey } from "./jobDetail/queryKeys"
import { CommandButton, useJobCommand } from "./jobDetail/command"
import { TagsPanel, NeedsAttentionBanner, FeedbackSourceBadge, EpicSummaryLink, TimelinePanel, AttachmentPreview, AttachmentCard, MergeablePill, JobStateBadge, PendingJobTitle, JobSourceLink, DependencyLink, PanelMessage, SmallPill, jobSourceLabel } from "./jobDetail/components"
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
      {payload.job.state === "queued" && payload.repository.landing_paused && payload.repository.main_health !== "healthy" ? (
        <div className="flex items-center gap-3 rounded border border-amber-200 bg-amber-50 px-4 py-3 text-sm dark:border-amber-900 dark:bg-amber-950/40" role="alert">
          <span className="text-amber-800 dark:text-amber-200">{t("main_branch_health_waiting")}</span>
          <Link className="shrink-0 rounded border border-amber-300 bg-white px-2 py-1 text-xs font-medium text-amber-800 hover:bg-amber-50 dark:border-amber-800 dark:bg-amber-950 dark:text-amber-200 dark:hover:bg-amber-900" to={withRoutePrefix(payload.repository.repository_path, prefix)}>
            {t("main_branch_health_view")}
          </Link>
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

      <TabNav active={activeTab} attachmentsCount={(payload.attachments ?? []).length} workflowsCount={payload.job.workflows_count} onSelect={onSelectTab} />

      {activeTab === "summary" ? <SummaryTab command={command} payload={payload} prefix={prefix} queryKey={queryKey} /> : null}
      {activeTab === "workflows" ? <WorkflowsTab command={command} payload={payload} prefix={prefix} /> : null}
      {activeTab === "attachments" ? <AttachmentsTab payload={payload} queryKey={queryKey} onNotice={setNotice} /> : null}
      {activeTab === "source" ? <SourceTab jobId={String(payload.job.id)} coverageInfo={latestWorkflowCoverage(payload.workflows)} /> : null}
    </>
  )
}

function TabNav({ active, workflowsCount, attachmentsCount, onSelect }: { active: JobTab; workflowsCount: number; attachmentsCount: number; onSelect: (tab: JobTab) => void }) {
  const { t } = useT("jobs")
  const tabs: Array<{ id: JobTab; label: string }> = [
    { id: "summary", label: t("tab_summary") },
    { id: "workflows", label: t("tab_workflows", { count: workflowsCount }) },
    { id: "attachments", label: t("tab_attachments", { count: attachmentsCount }) },
    { id: "source", label: t("tab_source") }
  ]

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
      {payload.unsatisfied_dependencies.length > 0 ? <UnsatisfiedDependencies command={command} payload={payload} prefix={prefix} /> : null}

      <div className="grid gap-4 lg:grid-cols-[62%_38%]">
        <div className="space-y-4">
          <section className="rounded border border-gray-200 bg-white p-4 dark:border-gray-700 dark:bg-gray-900">
            <h2 className="text-sm font-semibold text-gray-900 dark:text-gray-100">{t("section_issue")}</h2>
            {payload.job.issue_body ? <Markdown className="chat-prose mt-2 text-sm text-gray-700 dark:text-gray-300" text={payload.job.issue_body} /> : <p className="mt-2 text-sm text-gray-400 dark:text-gray-500">{t("no_issue_body")}</p>}
          </section>
          <section className="rounded border border-gray-200 bg-white p-4 dark:border-gray-700 dark:bg-gray-900">
            <h2 className="text-sm font-semibold text-gray-900 dark:text-gray-100">{t("section_agent_summary")}</h2>
            {payload.summary ? <p className="mt-2 whitespace-pre-wrap text-sm text-gray-700 dark:text-gray-300">{payload.summary.text}</p> : <p className="mt-2 text-sm text-gray-400 dark:text-gray-500">{t("no_summary")}</p>}
          </section>

          <TestPlanPanel testPlan={payload.test_plan} />

          {coverageInfo ? <CoverageCard coverage={coverageInfo.coverage} /> : null}

          <PendingFeedbackPanel jobId={payload.job.id} comments={payload.pending_feedback} queryKey={queryKey} />

          <FeedbackHistoryPanel prefix={prefix} workflows={payload.workflows} />

          <TimelinePanel canView={payload.actions.can_view_timeline} jobId={payload.job.id} prefix={prefix} runsCount={payload.job.runs_count} />
          <AttachmentPreview attachments={payload.attachments} />
        </div>

        <div className="space-y-4">
          <section className="rounded border border-gray-200 bg-white p-4 text-sm dark:border-gray-700 dark:bg-gray-900">
            <h2 className="font-semibold text-gray-900 dark:text-gray-100">{t("section_details")}</h2>
            <div className="mt-3 grid grid-cols-1 gap-x-4 gap-y-3 sm:grid-cols-2">
              <KeyValue label={t("detail_state")}><StatusPill state={payload.job.summary_state} /></KeyValue>
              <KeyValue label={t("detail_owner")}><JobOwnerLabel command={command} payload={payload} prefix={prefix} /></KeyValue>
              <KeyValue label={t("detail_priority")}><PrioritySelector currentPriority={payload.job.priority} priorityPath={payload.paths.app_priority_path} queryKey={queryKey} /></KeyValue>
              <KeyValue label={t("detail_validity")}><span className="capitalize">{payload.job.validity}</span></KeyValue>
              {payload.epic ? <KeyValue label={t("detail_epic")}><EpicSummaryLink epic={payload.epic} prefix={prefix} /></KeyValue> : null}
              {payload.job.branch_name ? <KeyValue label={t("detail_branch")}><code className="break-all">{payload.job.branch_name}</code></KeyValue> : null}
              <KeyValue label={t("detail_stack_base")}><StackBaseForm command={command} payload={payload} /></KeyValue>
              {payload.job.pr_number || payload.job.external_pr_number ? <KeyValue label={t("detail_pull_request")}><PullRequestSummary payload={payload} /></KeyValue> : null}
              <KeyValue label={t("detail_cost")}>{payload.job.total_cost_usd == null ? "-" : formatCurrency(payload.job.total_cost_usd)} <span className="text-xs text-gray-400 dark:text-gray-500">({payload.job.billed_runs_count} {t("detail_billed")})</span></KeyValue>
              <KeyValue label={t("detail_started")}><RelativeTimestamp value={payload.job.started_at} /></KeyValue>
              {payload.job.finished_at ? <KeyValue label={t("detail_closed")}><RelativeTimestamp value={payload.job.finished_at} /> ({payload.job.closure_reason || "unspecified"})</KeyValue> : null}
            </div>
            <TagsPanel canManageTags={payload.actions.can_manage_tags} embedded command={command} payload={payload} />
          </section>

          <ApprovalStatusPanel payload={payload} />
          <DependenciesPanel command={command} payload={payload} prefix={prefix} />
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
      {testPlan.notes ? <p className="mt-3 whitespace-pre-wrap text-sm text-gray-700 dark:text-gray-300">{testPlan.notes}</p> : null}
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

  if (comments.length === 0) return null

  const isPending = apply.isPending || ignore.isPending || replace.isPending

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
      {(apply.isError || ignore.isError || replace.isError) ? (
        <p className="mt-2 text-xs text-red-600 dark:text-red-400">
          {apply.error instanceof Error ? apply.error.message : ignore.error instanceof Error ? ignore.error.message : replace.error instanceof Error ? replace.error.message : "Action failed."}
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

function UnsatisfiedDependencies({ payload, command, prefix }: { payload: JobDetailPayload; command: ReturnType<typeof useJobCommand>; prefix: string }) {
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
                <DependencyLink dependency={dependency} prefix={prefix} />
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

function DependenciesPanel({ payload, command, prefix }: { payload: JobDetailPayload; command: ReturnType<typeof useJobCommand>; prefix: string }) {
  const { t } = useT("jobs")
  const [query, setQuery] = useState("")
  const [addingDependency, setAddingDependency] = useState(false)

  const trimmedQuery = query.trim()
  const filteredOptions = trimmedQuery.length > 0
    ? payload.dependency_target_options.filter((option) => option.label.toLowerCase().includes(trimmedQuery.toLowerCase()))
    : payload.dependency_target_options

  function choose(value: string) {
    command.mutate({ method: "post", path: payload.paths.app_dependencies_path, body: { dependency_target: value } }, { onSuccess: () => {
      setQuery("")
      setAddingDependency(false)
    }})
  }

  function cancelAdding() {
    setQuery("")
    setAddingDependency(false)
  }

  return (
    <div className="space-y-4">
      <div className="rounded border border-gray-200 bg-white p-4 text-sm dark:border-gray-700 dark:bg-gray-900">
        <h2 className="font-semibold text-gray-900 dark:text-gray-100">{t("section_dependencies")}</h2>
        {payload.dependencies.length > 0 ? (
          <ul className="mt-2 divide-y divide-gray-100 dark:divide-gray-800">
            {payload.dependencies.map((dependency) => (
              <li className="flex flex-wrap items-center justify-between gap-2 py-2" key={dependency.id}>
                <span><DependencyLink dependency={dependency} prefix={prefix} /> <span className="text-xs text-gray-400 dark:text-gray-500">({dependency.source})</span></span>
                {dependency.manual ? <button className="text-xs text-red-600 hover:underline" disabled={command.isPending} onClick={() => command.mutate({ method: "delete", path: `${payload.paths.app_dependencies_path}/${dependency.id}`, confirm: t("confirm_remove_dependency") })} type="button">{t("remove_dependency")}</button> : null}
              </li>
            ))}
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
        ) : (
          <div className="mt-3 border-t border-gray-100 pt-3 dark:border-gray-800">
            <button className="text-xs font-medium text-blue-600 hover:underline" onClick={() => setAddingDependency(true)} type="button">{t("add_dependency")}</button>
          </div>
        )}
      </div>
      {payload.dependents.length > 0 ? (
        <div className="rounded border border-gray-200 bg-white p-4 text-sm dark:border-gray-700 dark:bg-gray-900">
          <h2 className="font-semibold text-gray-900 dark:text-gray-100">{t("dependents_title", { count: payload.dependents.length })}</h2>
          <ul className="mt-2 divide-y divide-gray-100 dark:divide-gray-800">
            {payload.dependents.map((dependent) => (
              <li className="flex flex-wrap items-center gap-2 py-2" key={dependent.id}>
                <Link className="text-blue-600 hover:underline" to={withRoutePrefix(dependent.job.job_path, prefix)}>{dependent.job.repository_slug} {jobSlug(dependent.job.id)}</Link>
                <StatusPill state={dependent.job.summary_state} />
              </li>
            ))}
          </ul>
        </div>
      ) : null}
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



