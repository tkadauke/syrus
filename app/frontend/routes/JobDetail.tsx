import { keepPreviousData, useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import type { Dispatch, FormEvent, ReactNode, SetStateAction, UIEvent } from "react"
import { useEffect, useLayoutEffect, useMemo, useRef, useState } from "react"
import { Link, useLocation, useNavigate, useParams } from "react-router-dom"
import { useT } from "../hooks/useT"
import { ApiError } from "../api/client"
import { createTerminalSession } from "../api/terminal"
import { AnsiText } from "../components/AnsiText"
import { CloseIcon } from "../components/CloseIcon"
import { KeyValue } from "../components/KeyValue"
import { CopyableSlug } from "../components/CopyableSlug"
import { NoticeToast } from "../components/NoticeToast"
import { StatusPill } from "../components/StatusPill"
import { Markdown } from "../lib/Markdown"
import { workflowSlug } from "../lib/slugs"
import { highlightCode, type SyntaxLanguage } from "../lib/syntaxHighlight"
import { buttonClass, type ButtonTone } from "../lib/buttonClasses"
import { useDismissiblePopup } from "../lib/useDismissiblePopup"
import {
  applyPendingFeedback,
  createJobAttachments,
  deleteJobCommand,
  fetchJobDetail,
  fetchJobGradeLog,
  fetchJobRunArtifacts,
  fetchJobSource,
  fetchJobSourceDiff,
  fetchJobTimeline,
  fetchWorkflowCoverageHitMap,
  ignorePendingFeedback,
  patchJobCommand,
  postJobCommand,
  replacePendingFeedback,
  submitJobFeedback,
  type CoverageArtifact,
  type JobAttachment,
  type JobDependency,
  type JobApprovalRecord,
  type JobApprovalStatus,
  type JobDetailPayload,
  type JobRun,
  type JobSourceDiffPayload,
  type JobSourcePayload,
  type JobStep,
  type JobTestPlan,
  type JobWorkflow,
  type PendingFeedbackComment
} from "../api/jobs"
import { CoverageCard } from "../components/CoverageCard"

type JobTab = "summary" | "workflows" | "attachments" | "source"
type JobDetailQueryKey = readonly ["jobs", string, "detail", string]
type CommandInput =
  | { method: "post"; path: string; body?: unknown; confirm?: string }
  | { method: "patch"; path: string; body?: unknown; confirm?: string }
  | { method: "delete"; path: string; confirm?: string }
type HeaderAction = {
  key: string
  label: string
  input: CommandInput
  tone: ButtonTone
}
type BranchDivergence = {
  branch: string
  remote_sha: string | null
  local_sha: string | null
  detected_at: string | null
  message: string | null
}
type PrepareFailure = {
  command?: string
  workdir?: string
  exit_status?: number | null
  timed_out?: boolean
  stopped?: boolean
  operator_killed?: boolean
  aliveness_failed?: boolean
  duration_s?: number | null
  output_tail?: string | null
  // Set when the failed command was auto-detected (guessed) rather than
  // from .syrus.yml. Syrus skips it and runs the agent anyway.
  soft?: boolean
}

const RUN_TRANSCRIPT_BOTTOM_THRESHOLD_PX = 24

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
  const detail = useQuery({
    queryKey,
    queryFn: () => fetchJobDetail(id, detailSearch),
    enabled: id.length > 0
  })

  function selectTab(tab: JobTab) {
    const search = new URLSearchParams(location.search)
    if (tab === "summary") search.delete("tab")
    else search.set("tab", tab)
    if (tab !== "workflows") search.delete("workflows_page")
    const next = search.toString()
    navigate(`${location.pathname}${next ? `?${next}` : ""}`)
  }

  return (
    <main aria-label="Job" className="mx-auto max-w-[96rem] space-y-6 p-6">
      {detail.isPending ? <PanelMessage>{t("loading")}</PanelMessage> : null}
      {detail.isError ? <PanelMessage tone="error">{errorMessage(detail.error, t("load_error"))}</PanelMessage> : null}
      {detail.isSuccess ? <JobDetailView activeTab={activeTab} onSelectTab={selectTab} payload={detail.data} prefix={prefix} queryKey={queryKey} /> : null}
    </main>
  )
}

function jobDetailQueryKey(id: string | number, search: string): JobDetailQueryKey {
  return ["jobs", String(id), "detail", search] as const
}

function jobDetailSearch(search: string) {
  const current = new URLSearchParams(search)
  const next = new URLSearchParams()
  const workflowsPage = current.get("workflows_page")
  if (workflowsPage) next.set("workflows_page", workflowsPage)
  const value = next.toString()
  return value ? `?${value}` : ""
}

function tabFromLocation(pathname: string, search: string): JobTab {
  if (pathname.endsWith("/source")) return "source"

  const value = new URLSearchParams(search).get("tab")
  return value === "workflows" || value === "attachments" || value === "source" ? value : "summary"
}

export function JobDetailView({ payload, queryKey, activeTab, onSelectTab, prefix }: { payload: JobDetailPayload; queryKey: JobDetailQueryKey; activeTab: JobTab; onSelectTab: (tab: JobTab) => void; prefix: string }) {
  const { t } = useT("jobs")
  const location = useLocation()
  const queryClient = useQueryClient()
  const [notice, setNotice] = useState<string | null>(payload.message || null)
  const [feedbackPanelOpen, setFeedbackPanelOpen] = useState(false)
  const command = useJobCommand(payload.job.id, queryKey, setNotice)
  const title = payload.job.issue_title || jobSourceLabel(payload, t)
  const workflowAnchor = location.hash.startsWith("#workflow-") ? location.hash.slice(1) : null
  const renderedWorkflowIds = payload.workflows.map((workflow) => workflow.id).join(",")
  const feedback = useMutation({
    mutationFn: (body: string) => submitJobFeedback(payload.job.id, body),
    onSuccess: () => {
      setFeedbackPanelOpen(false)
      setNotice(t("feedback_submitted"))
      void queryClient.invalidateQueries({ queryKey: ["jobs", String(payload.job.id)] })
      void queryClient.invalidateQueries({ queryKey })
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
        <div className="flex flex-wrap items-start justify-between gap-3">
          <div className="min-w-0">
            <div className="flex flex-wrap items-start gap-3">
              <h1 className="break-words text-3xl font-semibold text-gray-900 dark:text-gray-100">
                <CopyableSlug slug={jobSlug(payload.job.id)} />
                <span className="px-2 text-gray-400 dark:text-gray-500">·</span>
                <PendingJobTitle pending={Boolean(payload.job.title_pending)} title={title} />
              </h1>
              <div className="mt-1.5 shrink-0"><JobStateBadge state={payload.job.summary_state} /></div>
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
          <HeaderActions
            command={command}
            feedbackPanelOpen={feedbackPanelOpen}
            onToggleFeedbackPanel={() => setFeedbackPanelOpen((current) => !current)}
            payload={payload}
          />
        </div>
      </header>

      <NoticeToast message={notice} onDismiss={() => setNotice(null)} />
      {command.isError ? <PanelMessage tone="error">{errorMessage(command.error, t("command_error"))}</PanelMessage> : null}
      {feedbackPanelOpen ? (
        <JobFeedbackPanel
          error={feedback.error}
          isPending={feedback.isPending}
          onCancel={() => setFeedbackPanelOpen(false)}
          onSubmit={(body) => feedback.mutate(body)}
        />
      ) : null}

      <TabNav active={activeTab} attachmentsCount={payload.attachments.length} workflowsCount={payload.job.workflows_count} onSelect={onSelectTab} />

      {activeTab === "summary" ? <SummaryTab command={command} payload={payload} prefix={prefix} queryKey={queryKey} /> : null}
      {activeTab === "workflows" ? <WorkflowsTab command={command} payload={payload} prefix={prefix} /> : null}
      {activeTab === "attachments" ? <AttachmentsTab payload={payload} queryKey={queryKey} onNotice={setNotice} /> : null}
      {activeTab === "source" ? <SourceTab jobId={String(payload.job.id)} coverageInfo={latestWorkflowCoverage(payload.workflows)} /> : null}
    </>
  )
}

function ChatBubbleIcon() {
  return (
    <svg aria-hidden="true" className="h-3.5 w-3.5" fill="none" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="2" viewBox="0 0 24 24">
      <path d="M21 11.5a8.4 8.4 0 0 1-.9 3.8 8.5 8.5 0 0 1-7.6 4.7 8.4 8.4 0 0 1-3.8-.9L3 21l1.9-5.7a8.4 8.4 0 0 1-.9-3.8 8.5 8.5 0 0 1 17 0Z" />
    </svg>
  )
}

function useJobCommand(jobId: number, queryKey: JobDetailQueryKey, onNotice: (message: string | null) => void) {
  const queryClient = useQueryClient()
  const navigate = useNavigate()

  return useMutation({
    mutationFn: (input: CommandInput) => {
      if (input.confirm && !window.confirm(input.confirm)) return Promise.resolve({ message: null })
      if (input.method === "delete") return deleteJobCommand(input.path)
      if (input.method === "patch") return patchJobCommand(input.path, input.body)
      return postJobCommand(input.path, input.body)
    },
    onSuccess: (payload) => {
      if (payload.redirect_to) navigate(payload.redirect_to)
      onNotice(payload.message || null)
      void queryClient.invalidateQueries({ queryKey: ["jobs", String(jobId)] })
      void queryClient.invalidateQueries({ queryKey })
    }
  })
}

function HeaderActions({ payload, command, feedbackPanelOpen, onToggleFeedbackPanel }: { payload: JobDetailPayload; command: ReturnType<typeof useJobCommand>; feedbackPanelOpen: boolean; onToggleFeedbackPanel: () => void }) {
  const { t } = useT("jobs")
  const [retryFeedbackOpen, setRetryFeedbackOpen] = useState(false)
  const actions = headerActions(payload, t)
  const visibleKeys = primaryHeaderActionKeys(payload, actions)
  const visibleActions = visibleKeys.map((key) => actions.find((action) => action.key === key)).filter((action): action is HeaderAction => Boolean(action))
  const overflowActions = actions.filter((action) => !visibleKeys.includes(action.key))
  const canGiveFeedback = ["implemented", "failed"].includes(payload.job.state)

  return (
    <>
      <div className="flex flex-wrap items-center justify-end gap-2">
        {canGiveFeedback ? (
          <button
            aria-expanded={feedbackPanelOpen}
            className={buttonClass("secondary")}
            onClick={onToggleFeedbackPanel}
            type="button"
          >
            {t("give_feedback")}
          </button>
        ) : null}
        {visibleActions.map((action) => (
          <CommandButton command={command} input={action.input} key={action.key} tone={action.tone}>{action.label}</CommandButton>
        ))}
        {overflowActions.length > 0 ? <HeaderActionsMenu actions={overflowActions} command={command} onRetryFeedback={() => setRetryFeedbackOpen(true)} /> : null}
      </div>
      {retryFeedbackOpen ? (
        <RetryFeedbackDialog
          command={command}
          onClose={() => setRetryFeedbackOpen(false)}
          path={payload.actions.retry_implementation_action?.path || payload.paths.app_run_again_path}
        />
      ) : null}
    </>
  )
}

function JobFeedbackPanel({ error, isPending, onCancel, onSubmit }: { error: Error | null; isPending: boolean; onCancel: () => void; onSubmit: (body: string) => void }) {
  const { t } = useT("jobs")
  const [body, setBody] = useState("")
  const trimmedBody = body.trim()

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (!trimmedBody) return

    onSubmit(trimmedBody)
  }

  return (
    <section aria-labelledby="job-feedback-title" className="rounded border border-blue-200 bg-blue-50/60 p-4 dark:border-blue-900/60 dark:bg-blue-950/20">
      <form className="space-y-3" onSubmit={submit}>
        <h2 className="text-sm font-semibold text-gray-900 dark:text-gray-100" id="job-feedback-title">{t("feedback_panel_title")}</h2>
        <textarea
          className="w-full rounded border border-gray-300 bg-white px-3 py-2 text-sm text-gray-900 shadow-sm focus:outline-blue-600 dark:border-gray-700 dark:bg-gray-950 dark:text-gray-100"
          disabled={isPending}
          onChange={(event) => setBody(event.target.value)}
          placeholder={t("feedback_placeholder")}
          rows={4}
          value={body}
        />
        {error ? <p className="text-sm text-red-700 dark:text-red-300" role="alert">{errorMessage(error, t("feedback_error"))}</p> : null}
        <div className="flex flex-wrap justify-end gap-2">
          <button className={buttonClass("secondary")} disabled={isPending} onClick={onCancel} type="button">{t("cancel")}</button>
          <button className={buttonClass("primary")} disabled={isPending || !trimmedBody} type="submit">
            {isPending ? t("submitting") : t("submit_feedback")}
          </button>
        </div>
      </form>
    </section>
  )
}

function headerActions(payload: JobDetailPayload, t: ReturnType<typeof useT>["t"]): HeaderAction[] {
  const actions = payload.actions
  const paths = payload.paths
  const available: HeaderAction[] = []

  if (actions.can_start) available.push({ key: "start", label: t("start_run"), input: { method: "post", path: paths.app_start_path }, tone: "primary" })
  if (actions.can_poll_feedback) available.push({ key: "poll_feedback", label: t("check_feedback"), input: { method: "post", path: paths.app_poll_feedback_path }, tone: "secondary" })
  if (actions.can_rebase) available.push({ key: "rebase", label: t("rebase_now"), input: { method: "post", path: paths.app_rebase_path }, tone: "secondary" })
  if (actions.can_check_mergeability) available.push({ key: "check_mergeability", label: t("check_mergeability"), input: { method: "post", path: paths.app_check_mergeability_path }, tone: "secondary" })
  if (actions.retry_failed_step_action) available.push({ key: "retry_failed_step", label: actions.retry_failed_step_action.label, input: { method: "post", path: actions.retry_failed_step_action.path }, tone: "primary" })
  if (actions.retry_implementation_action) available.push({ key: "retry_implementation", label: actions.retry_implementation_action.label, input: { method: "post", path: actions.retry_implementation_action.path }, tone: "primary" })
  if (actions.retry_implementation_action) available.push({ key: "retry_feedback", label: t("retry_with_feedback"), input: { method: "post", path: actions.retry_implementation_action.path }, tone: "secondary" })
  if (actions.can_restart) available.push({ key: "restart", label: t("start_over"), input: { method: "post", path: paths.app_restart_path, confirm: t("confirm_start_over") }, tone: "secondary" })
  if (actions.can_approve) available.push({ key: "approve", label: payload.job.landing_failure_reason ? t("reapprove") : t("approve"), input: { method: "post", path: paths.app_approve_path }, tone: "success" })
  if (actions.can_unapprove) available.push({ key: "unapprove", label: t("unapprove"), input: { method: "post", path: paths.app_unapprove_path, confirm: t("confirm_unapprove") }, tone: "secondary" })
  if (actions.can_cancel) available.push({ key: "cancel", label: t("cancel"), input: { method: "post", path: paths.app_cancel_path, confirm: t("confirm_cancel") }, tone: "danger" })
  if (actions.can_reopen) available.push({ key: "reopen", label: t("reopen"), input: { method: "post", path: paths.app_reopen_path }, tone: "success" })
  if (actions.can_mark_valid) available.push({ key: "mark_valid", label: t("mark_valid"), input: { method: "post", path: paths.app_mark_valid_path }, tone: "secondary" })
  if (actions.can_open_in_coding_mode) available.push({ key: "open_in_coding_mode", label: t("open_in_coding_mode"), input: { method: "post", path: paths.app_open_in_coding_mode_path }, tone: "secondary" })
  available.push({ key: "pin", label: payload.pinned ? t("unpin") : t("pin"), input: payload.pinned ? { method: "delete", path: paths.app_pin_path } : { method: "post", path: paths.app_pin_path }, tone: "secondary" })

  return available
}

function primaryHeaderActionKeys(payload: JobDetailPayload, actions: HeaderAction[]) {
  const availableKeys = new Set(actions.map((action) => action.key))
  const jobState = payload.job.summary_state.toLowerCase()
  const keys: string[] = []

  function add(key: string) {
    if (availableKeys.has(key) && keys.length < 2) keys.push(key)
  }

  if (payload.job.any_active_run || jobState === "running") {
    add("cancel")
  } else if (availableKeys.has("approve")) {
    add("approve")
    add("retry_failed_step")
  } else if (jobState === "failed") {
    add("retry_failed_step")
    add("retry_implementation")
    add("restart")
  } else if (availableKeys.has("reopen")) {
    add("reopen")
  } else if (availableKeys.has("retry_failed_step")) {
    add("retry_failed_step")
  } else if (availableKeys.has("retry_implementation")) {
    add("retry_implementation")
  } else {
    add("start")
    add("mark_valid")
  }

  return keys
}

function HeaderActionsMenu({ actions, command, onRetryFeedback }: { actions: HeaderAction[]; command: ReturnType<typeof useJobCommand>; onRetryFeedback: () => void }) {
  const [open, setOpen] = useState(false)
  const [alignRight, setAlignRight] = useState(true)
  const menuRef = useDismissiblePopup<HTMLDivElement>(open, () => setOpen(false))
  const buttonRef = useRef<HTMLButtonElement>(null)

  function handleToggle() {
    if (!open && buttonRef.current) {
      // w-56 = 224px; open left only when the button has enough room to the left
      setAlignRight(buttonRef.current.getBoundingClientRect().right >= 224)
    }
    setOpen((current) => !current)
  }

  return (
    <div className="relative" ref={menuRef}>
      <button
        aria-expanded={open}
        aria-haspopup="menu"
        className={buttonClass("secondary")}
        disabled={command.isPending}
        onClick={handleToggle}
        ref={buttonRef}
        type="button"
      >
        ⋯
      </button>
      {open ? (
        <div className={`absolute ${alignRight ? "right-0" : "left-0"} z-20 mt-2 w-56 rounded border border-gray-200 bg-white py-1 shadow-lg dark:border-gray-700 dark:bg-gray-900`} role="menu">
          {actions.map((action) => (
            <button
              className={menuButtonClass(action.tone)}
              disabled={command.isPending}
              key={action.key}
              onClick={() => {
                setOpen(false)
                if (action.key === "retry_feedback") {
                  onRetryFeedback()
                  return
                }
                command.mutate(action.input)
              }}
              role="menuitem"
              type="button"
            >
              {action.label}
            </button>
          ))}
        </div>
      ) : null}
    </div>
  )
}

function RetryFeedbackDialog({ command, path, onClose }: { command: ReturnType<typeof useJobCommand>; path: string; onClose: () => void }) {
  const { t } = useT("jobs")
  const [feedback, setFeedback] = useState("")
  const trimmedFeedback = feedback.trim()

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (!trimmedFeedback) return

    command.mutate(
      { method: "post", path, body: { retry_context: trimmedFeedback } },
      { onSuccess: onClose }
    )
  }

  return (
    <div className="fixed inset-0 z-30 flex items-center justify-center bg-gray-900/40 p-4" role="presentation">
      <section aria-labelledby="retry-feedback-title" className="w-full max-w-lg rounded border border-gray-200 bg-white p-4 shadow-xl dark:border-gray-700 dark:bg-gray-900" role="dialog" aria-modal="true">
        <div className="flex items-start justify-between gap-3">
          <div>
            <h2 className="text-base font-semibold text-gray-900 dark:text-gray-100" id="retry-feedback-title">{t("retry_feedback_title")}</h2>
            <p className="mt-1 text-sm text-gray-500 dark:text-gray-400">{t("retry_feedback_description")}</p>
          </div>
          <button
            aria-label={t("close_retry_feedback")}
            className="inline-flex h-8 w-8 items-center justify-center rounded text-gray-500 hover:bg-gray-100 hover:text-gray-700 dark:text-gray-400 dark:hover:bg-gray-800 dark:hover:text-gray-200"
            disabled={command.isPending}
            onClick={onClose}
            type="button"
          >
            <CloseIcon className="h-4 w-4" />
          </button>
        </div>
        <form className="mt-4 space-y-3" onSubmit={submit}>
          <label className="block text-sm font-medium text-gray-700 dark:text-gray-300" htmlFor="retry-feedback-text">
            {t("retry_feedback_label")}
          </label>
          <textarea
            autoFocus
            className="min-h-36 w-full rounded border border-gray-300 bg-white px-3 py-2 text-sm text-gray-900 shadow-sm focus:outline-blue-600 dark:border-gray-700 dark:bg-gray-950 dark:text-gray-100"
            id="retry-feedback-text"
            onChange={(event) => setFeedback(event.target.value)}
            required
            value={feedback}
          />
          <div className="flex flex-wrap justify-end gap-2">
            <button className={buttonClass("secondary")} disabled={command.isPending} onClick={onClose} type="button">{t("cancel")}</button>
            <button className={buttonClass("primary")} disabled={command.isPending || !trimmedFeedback} type="submit">
              {command.isPending ? t("retrying") : t("retry")}
            </button>
          </div>
        </form>
      </section>
    </div>
  )
}

function CommandButton({ children, command, input, tone = "primary" }: { children: ReactNode; command: ReturnType<typeof useJobCommand>; input: CommandInput; tone?: ButtonTone }) {
  return (
    <button className={buttonClass(tone)} disabled={command.isPending} onClick={() => command.mutate(input)} type="button">
      {children}
    </button>
  )
}

function TagsPanel({ payload, command, embedded = false, canManageTags }: { payload: JobDetailPayload; command: ReturnType<typeof useJobCommand>; embedded?: boolean; canManageTags: boolean }) {
  const { t } = useT("jobs")
  const [tagName, setTagName] = useState("")
  const [addingTag, setAddingTag] = useState(false)

  if (payload.tags.length === 0 && !canManageTags) return null

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    command.mutate(
      { method: "post", path: payload.paths.app_tags_path, body: { tag_name: tagName } },
      { onSuccess: () => { setTagName(""); setAddingTag(false) } }
    )
  }

  const content = (
    <div className="space-y-2">
      <div className="flex min-w-0 flex-wrap items-center gap-2">
        <h2 className="text-sm font-semibold text-gray-900 dark:text-gray-100">{t("section_tags")}</h2>
        {payload.tags.map((tag) => (
          <span className="inline-flex items-center gap-1.5 whitespace-nowrap rounded-full bg-gray-100 px-2 py-0.5 text-xs text-gray-700 dark:bg-gray-800 dark:text-gray-200" key={tag.id}>
            {tag.name}
            {canManageTags ? (
              <button
                aria-label={t("tags_remove_aria", { name: tag.name })}
                className="inline-flex h-4 w-4 items-center justify-center rounded text-gray-400 hover:bg-gray-200 hover:text-red-600 dark:text-gray-500 dark:hover:bg-gray-700 dark:hover:text-red-300"
                disabled={command.isPending}
                onClick={() => command.mutate({ method: "delete", path: `${payload.paths.app_tags_path}/${tag.id}` })}
                title={t("tags_remove_aria", { name: tag.name })}
                type="button"
              >
                <CloseIcon className="h-3 w-3" />
              </button>
            ) : null}
          </span>
        ))}
      </div>
      {canManageTags ? (
        addingTag ? (
          <form className="flex items-center gap-2" onSubmit={submit}>
            <input className="w-40 rounded border border-gray-300 bg-white px-2 py-1.5 text-sm text-gray-900 dark:border-gray-700 dark:bg-gray-950 dark:text-gray-100" list="job-tag-options" onChange={(event) => setTagName(event.target.value)} placeholder={t("tags_placeholder")} required value={tagName} />
            <datalist id="job-tag-options">
              {payload.tag_options.map((tag) => <option key={tag.id} value={tag.name} />)}
            </datalist>
            <button className={buttonClass("secondary")} disabled={command.isPending} type="submit">{t("tags_add")}</button>
            <button className="text-xs text-gray-500 hover:underline disabled:cursor-not-allowed disabled:opacity-50" disabled={command.isPending} onClick={() => setAddingTag(false)} type="button">{t("tags_cancel")}</button>
          </form>
        ) : (
          <button className="text-xs font-medium text-blue-600 hover:underline" onClick={() => setAddingTag(true)} type="button">{t("tags_add_tag")}</button>
        )
      ) : null}
    </div>
  )

  if (embedded) {
    return (
      <div className="mt-3 border-t border-gray-100 pt-3 dark:border-gray-800">
        {content}
      </div>
    )
  }

  return (
    <section className="rounded border border-gray-200 bg-white p-4 dark:border-gray-700 dark:bg-gray-900">
      {content}
    </section>
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
          className={`shrink-0 border-b-2 px-4 py-2 text-sm font-medium ${active === tab.id ? "border-blue-600 text-blue-600 dark:border-blue-400 dark:text-blue-300" : "border-transparent text-gray-500 hover:text-gray-800 dark:text-gray-400 dark:hover:text-gray-200"}`}
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

function NeedsAttentionBanner({ job }: { job: JobDetailPayload["job"] }) {
  if (!job.needs_attention) return null

  const messages: Record<string, string> = {
    fork_pr_closed: "The fork review PR was closed without being merged.",
    fork_pr_changes_requested: "A reviewer has requested changes on the fork review PR. The upstream PR will not be created until all outstanding review requests are resolved (approved or dismissed).",
    upstream_pr_closed: "The upstream PR was closed without being merged.",
    upstream_pr_changes_requested: "A reviewer has requested changes on the upstream PR. Auto-merge is paused until the review is resolved (approved or dismissed)."
  }

  const message = job.needs_attention_reason ? messages[job.needs_attention_reason] ?? `Needs attention: ${job.needs_attention_reason}` : "This job needs attention."

  const gracePeriodText = job.grace_period_expires_at ? (() => {
    const expires = new Date(job.grace_period_expires_at)
    const now = new Date()
    const ms = expires.getTime() - now.getTime()
    if (ms <= 0) return "Grace period has expired."
    const totalSeconds = Math.floor(ms / 1000)
    const days = Math.floor(totalSeconds / 86400)
    const hours = Math.floor((totalSeconds % 86400) / 3600)
    const minutes = Math.floor((totalSeconds % 3600) / 60)
    if (days > 0) return `Branch cleanup in ${days}d ${hours}h unless the PR is reopened.`
    if (hours > 0) return `Branch cleanup in ${hours}h ${minutes}m unless the PR is reopened.`
    return `Branch cleanup in ${minutes}m unless the PR is reopened.`
  })() : null

  return (
    <div className="rounded border border-amber-200 bg-amber-50 p-4 text-sm text-amber-800 dark:border-amber-800 dark:bg-amber-950/40 dark:text-amber-200">
      <p className="font-medium">Action needed</p>
      <p className="mt-1">{message}</p>
      {gracePeriodText ? <p className="mt-1 text-amber-700 dark:text-amber-300">{gracePeriodText}</p> : null}
    </div>
  )
}

function latestWorkflowCoverage(workflows: JobWorkflow[]): { workflowId: number; coverage: CoverageArtifact } | null {
  for (let i = workflows.length - 1; i >= 0; i--) {
    const cov = workflows[i].artifacts["coverage"] as CoverageArtifact | undefined
    if (cov) return { workflowId: workflows[i].id, coverage: cov }
  }
  return null
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
          {payload.landing_queue_entry.blocked_reason ? ` (${payload.landing_queue_entry.blocked_reason})` : ""}
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
            <div className="mt-3 grid grid-cols-2 gap-x-4 gap-y-3">
              <KeyValue label={t("detail_state")}><StatusPill state={payload.job.summary_state} /></KeyValue>
              <KeyValue label={t("detail_owner")}><JobOwnerLabel command={command} payload={payload} prefix={prefix} /></KeyValue>
              <KeyValue label={t("detail_priority")}><SmallPill>{payload.job.priority}</SmallPill></KeyValue>
              <KeyValue label={t("detail_validity")}><span className="capitalize">{payload.job.validity}</span></KeyValue>
              {payload.epic ? <KeyValue label={t("detail_epic")}><EpicSummaryLink epic={payload.epic} prefix={prefix} /></KeyValue> : null}
              {payload.job.branch_name ? <KeyValue label={t("detail_branch")}><code className="break-all">{payload.job.branch_name}</code></KeyValue> : null}
              <KeyValue label={t("detail_stack_base")}><StackBaseForm command={command} payload={payload} /></KeyValue>
              {payload.job.pr_number || payload.job.external_pr_number ? <KeyValue label={t("detail_pull_request")}><PullRequestSummary payload={payload} /></KeyValue> : null}
              <KeyValue label={t("detail_cost")}>{payload.job.total_cost_usd == null ? "-" : formatCurrency(payload.job.total_cost_usd)} <span className="text-xs text-gray-400 dark:text-gray-500">({payload.job.billed_runs_count} {t("detail_billed")})</span></KeyValue>
              <KeyValue label={t("detail_started")}>{formatDate(payload.job.started_at)}</KeyValue>
              {payload.job.finished_at ? <KeyValue label={t("detail_closed")}>{formatDate(payload.job.finished_at)} ({payload.job.closure_reason || "unspecified"})</KeyValue> : null}
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
      <h2 className="text-sm font-semibold text-amber-900 dark:text-amber-200">Pending feedback</h2>
      <p className="mt-1 text-xs text-amber-700 dark:text-amber-400">
        These PR comments require your decision before Syrus acts on them.
      </p>
      {notice ? (
        <div className="mt-2 flex items-center justify-between gap-2 rounded bg-amber-100 px-3 py-2 text-xs text-amber-800 dark:bg-amber-900/40 dark:text-amber-300">
          <span>{notice}</span>
          <button className="ml-2 hover:underline" onClick={() => setNotice(null)} type="button">Dismiss</button>
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
              {comment.comment_created_at ? <span>· {formatDate(comment.comment_created_at)}</span> : null}
            </div>
            <p className="mt-2 whitespace-pre-wrap break-words text-sm text-gray-700 dark:text-gray-300">{comment.body}</p>
            {replaceId === comment.id ? (
              <div className="mt-3 space-y-2">
                <textarea
                  aria-label="Replacement feedback text"
                  className="block w-full rounded border border-gray-300 bg-white px-3 py-2 text-sm focus:outline-blue-600 dark:border-gray-600 dark:bg-gray-800 dark:text-gray-200"
                  onChange={(e) => setReplaceBody(e.target.value)}
                  placeholder="Enter your replacement feedback text…"
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
          const chatFeedback = workflow.artifacts.chat_feedback
          return (
            <div className="mt-3 border-t border-gray-100 pt-3 first:mt-0 first:border-t-0 first:pt-0 dark:border-gray-800" key={workflow.id}>
              <div className="flex flex-wrap items-center justify-between gap-2">
                <div className="flex flex-wrap items-center gap-2">
                  <span className="text-sm font-medium text-gray-900 dark:text-gray-100">{feedbackTriggerLabel(workflow.trigger_kind, t)}</span>
                  <StatusPill state={workflow.state} />
                </div>
                <div className="flex flex-wrap items-center gap-2 text-xs text-gray-500 dark:text-gray-400">
                  <span>{formatDate(workflow.created_at)}</span>
                  <Link className="text-blue-600 hover:underline dark:text-blue-300" to={withRoutePrefix(workflow.path, prefix)}>
                    {workflow.slug || workflowSlug(workflow.id)}
                  </Link>
                </div>
              </div>
              {workflow.trigger_kind === "chat_feedback" ? (
                <>
                  <FeedbackSourceBadge source={workflow.artifacts.feedback_source} />
                  <pre className="mt-2 whitespace-pre-wrap break-words text-sm text-gray-700 dark:text-gray-300">{typeof chatFeedback === "string" ? chatFeedback : ""}</pre>
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

function FeedbackSourceBadge({ source }: { source: unknown }) {
  if (!source || typeof source !== "object") return null

  const s = source as Record<string, unknown>
  const attributedTo = typeof s.attributed_to === "string" ? s.attributed_to : null
  const githubHandle = typeof s.github_handle === "string" ? s.github_handle : null
  const action = typeof s.action === "string" ? s.action : null
  const confirmedBy = typeof s.confirmed_by === "string" ? s.confirmed_by : null

  if (!attributedTo && !githubHandle) return null

  const label = [
    githubHandle ? `@${githubHandle}` : null,
    attributedTo,
    confirmedBy ? `confirmed by ${confirmedBy}` : null,
    action === "replace" ? "(replaced)" : null
  ].filter(Boolean).join(" · ")

  return (
    <p className="mt-1 text-xs text-gray-500 dark:text-gray-400">{label}</p>
  )
}

function feedbackTriggerLabel(triggerKind: string, t: ReturnType<typeof useT>["t"]) {
  if (triggerKind === "chat_feedback") return t("feedback_trigger_chat")
  if (triggerKind === "pr_comment") return t("feedback_trigger_pr")
  return triggerKind.replaceAll("_", " ")
}

function workflowCreatedAtTime(workflow: JobWorkflow) {
  if (!workflow.created_at) return 0
  const time = Date.parse(workflow.created_at)
  return Number.isNaN(time) ? 0 : time
}

function EpicSummaryLink({ epic, prefix }: { epic: NonNullable<JobDetailPayload["epic"]>; prefix: string }) {
  return (
    <Link className="text-blue-600 hover:underline" to={withRoutePrefix(epic.epic_path, prefix)}>
      {epic.display_number} {epic.title}
    </Link>
  )
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
        {retry.next_auto_retry_at ? <span>{t("retry_state_next_retry")} {formatDate(retry.next_auto_retry_at)}</span> : null}
        {retry.retry_delayed_until ? <span>{t("retry_state_delayed_until")} {formatDate(retry.retry_delayed_until)}</span> : null}
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
          {payload.job.claimed_at ? <span className="text-xs text-gray-400 dark:text-gray-500">{formatDate(payload.job.claimed_at)}</span> : null}
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
      <div><MergeablePill value={payload.job.pr_mergeable} /> {payload.job.pr_mergeable_checked_at ? <span className="text-xs text-gray-400 dark:text-gray-500">{t("pr_checked")} {formatDate(payload.job.pr_mergeable_checked_at)}</span> : null}</div>
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
                  <span className="ml-2 shrink-0 text-gray-400 dark:text-gray-500">{new Date(approval.approved_at).toLocaleDateString()}</span>
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

function TimelinePanel({ canView, jobId, prefix, runsCount }: { canView: boolean; jobId: number; prefix: string; runsCount: number }) {
  const { t } = useT("jobs")
  const [expanded, setExpanded] = useState(false)
  const timeline = useQuery({
    queryKey: ["jobs", String(jobId), "timeline"],
    queryFn: () => fetchJobTimeline(String(jobId)),
    enabled: canView && expanded
  })

  if (!canView) return null

  return (
    <section className="rounded border border-gray-200 bg-white dark:border-gray-700 dark:bg-gray-900">
      <button
        aria-expanded={expanded}
        className="flex w-full items-center gap-2 p-4 text-left text-sm font-semibold text-gray-900 hover:bg-gray-50 dark:text-gray-100 dark:hover:bg-gray-800"
        onClick={() => setExpanded((value) => !value)}
        type="button"
      >
        <svg aria-hidden="true" className={`h-3 w-3 shrink-0 transition-transform ${expanded ? "rotate-90" : ""}`} fill="currentColor" viewBox="0 0 20 20">
          <path clipRule="evenodd" d="M7.21 14.77a.75.75 0 0 1 .02-1.06L11.17 10 7.23 6.29a.75.75 0 0 1 1.04-1.08l4.5 4.25a.75.75 0 0 1 0 1.08l-4.5 4.25a.75.75 0 0 1-1.06-.02Z" fillRule="evenodd" />
        </svg>
        {t("section_timeline")} <span className="font-normal text-gray-500 dark:text-gray-400">{t("timeline_runs", { count: runsCount })}</span>
      </button>
      {expanded ? (
        <div className="border-t border-gray-100 px-4 pb-4 dark:border-gray-800">
          {timeline.isPending ? <p className="mt-3 text-sm text-gray-400 dark:text-gray-500">{t("timeline_loading")}</p> : null}
          {timeline.isError ? <p className="mt-3 text-sm text-red-700">{errorMessage(timeline.error || new Error("Timeline failed."), t("timeline_error"))}</p> : null}
          {timeline.data && timeline.data.events.length > 0 ? (
            <ol className="mt-3 space-y-3">
              {timeline.data.events.map((event, index) => (
                <li className="border-l border-gray-200 pl-3 text-sm dark:border-gray-700" key={`${event.at}-${event.title}-${index}`}>
                  <div className="font-medium text-gray-900 dark:text-gray-100">
                    {event.workflow_path ? (
                      <Link className="text-blue-600 underline hover:no-underline" to={withRoutePrefix(event.workflow_path, prefix)}>{event.title}</Link>
                    ) : event.title}
                  </div>
                  <div className="text-xs text-gray-500 dark:text-gray-400">
                    {formatDate(event.at)} · {event.source}
                    {event.ref_label ? (
                      <>
                        {" · "}
                        {event.workflow_path ? (
                          <Link className="text-blue-600 underline hover:no-underline" to={withRoutePrefix(event.workflow_path, prefix)}>{event.ref_label}</Link>
                        ) : event.ref_label}
                      </>
                    ) : null}
                  </div>
                  {event.detail ? <div className="mt-1 text-gray-600 dark:text-gray-300">{event.detail}</div> : null}
                </li>
              ))}
            </ol>
          ) : null}
        </div>
      ) : null}
    </section>
  )
}

function AttachmentPreview({ attachments }: { attachments: JobAttachment[] }) {
  const { t } = useT("jobs")
  if (attachments.length === 0) return null

  return (
    <section className="rounded border border-gray-200 bg-white p-4 dark:border-gray-700 dark:bg-gray-900">
      <h2 className="text-sm font-semibold text-gray-900 dark:text-gray-100">{t("section_attachments")}</h2>
      <div className="mt-3 grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
        {attachments.slice(0, 6).map((attachment) => <AttachmentCard attachment={attachment} key={attachment.id} />)}
      </div>
    </section>
  )
}

function WorkflowsTab({ payload, command, prefix }: { payload: JobDetailPayload; command: ReturnType<typeof useJobCommand>; prefix: string }) {
  const { t } = useT("jobs")
  if (payload.workflows.length === 0) return <PanelMessage>{t("section_no_workflows")}</PanelMessage>

  return (
    <div className="space-y-4">
      <WorkflowsPagination payload={payload} prefix={prefix} />
      {payload.workflows.map((workflow) => <WorkflowCard command={command} key={workflow.id} payload={payload} prefix={prefix} workflow={workflow} />)}
      <WorkflowsPagination payload={payload} prefix={prefix} />
    </div>
  )
}

function WorkflowsPagination({ payload, prefix }: { payload: JobDetailPayload; prefix: string }) {
  const { t } = useT("jobs")
  const pagination = payload.workflows_pagination
  if (pagination.total_pages <= 1) return null

  return (
    <nav aria-label="Workflow pagination" className="flex items-center justify-between text-sm text-gray-600 dark:text-gray-400">
      <span>{t("workflows_showing", { first: pagination.first_item, last: pagination.last_item, total: pagination.total_workflows })}</span>
      <div className="flex gap-2">
        {pagination.previous_path ? <Link className={paginationLinkClass()} to={withRoutePrefix(pagination.previous_path, prefix)}>{t("workflows_previous")}</Link> : <span className={disabledPaginationClass()}>{t("workflows_previous")}</span>}
        {pagination.next_path ? <Link className={paginationLinkClass()} to={withRoutePrefix(pagination.next_path, prefix)}>{t("workflows_next")}</Link> : <span className={disabledPaginationClass()}>{t("workflows_next")}</span>}
      </div>
    </nav>
  )
}

function WorkflowCard({ workflow, payload, command, prefix }: { workflow: JobWorkflow; payload: JobDetailPayload; command: ReturnType<typeof useJobCommand>; prefix: string }) {
  const { t } = useT("jobs")
  const stepItems = workflowStepItems(workflow.steps)
  const branchDivergence = workflowBranchDivergence(workflow)
  const navigate = useNavigate()
  const [terminalOpening, setTerminalOpening] = useState(false)

  async function openTerminal() {
    setTerminalOpening(true)
    try {
      const { session } = await createTerminalSession({
        workflow_id: workflow.id,
        name: `${workflow.slug || workflowSlug(workflow.id)} workspace`
      })
      setTerminalOpening(false)
      navigate(`${prefix}/terminal?session=${session.id}`)
    } catch (error) {
      setTerminalOpening(false)
      throw error
    }
  }

  return (
    <section className="rounded border border-gray-200 bg-white p-4 dark:border-gray-700 dark:bg-gray-900" id={`workflow-${workflow.id}`}>
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h2 className="text-sm font-semibold text-gray-900 dark:text-gray-100">
            <Link className="hover:underline" to={withRoutePrefix(workflow.path, prefix)}>{workflow.slug || workflowSlug(workflow.id)}</Link>
          </h2>
          <p className="text-xs text-gray-500 dark:text-gray-400">{workflow.trigger_kind} · {workflow.agent_provider || t("workflow_default_agent")} · {t("workflow_created")} {formatDate(workflow.created_at)}</p>
        </div>
        <div className="flex flex-wrap items-center gap-2">
          {workflow.state === "running" ? null : <StatusPill state={workflow.state} />}
          {payload.feature_flags?.terminal ? (
            <button className={buttonClass("secondary")} disabled={terminalOpening} onClick={openTerminal} type="button">
              {t("open_terminal_in_workspace")}
            </button>
          ) : null}
          {workflow.retry_available ? <CommandButton command={command} input={{ method: "post", path: workflow.app_retry_step_path }} tone="secondary">{t("retry_failed_step")}</CommandButton> : null}
          {workflow.state === "failed" && !workflow.cleaned_up_at ? <CommandButton command={command} input={{ method: "post", path: workflow.app_push_commits_path }} tone="secondary">{t("push_commits")}</CommandButton> : null}
        </div>
      </div>
      {branchDivergence ? <BranchDivergencePanel command={command} divergence={branchDivergence} payload={payload} prefix={prefix} workflow={workflow} /> : null}
      <div className="mt-4 overflow-hidden rounded border border-gray-200 dark:border-gray-700">
        {stepItems.map((item, index) => item.type === "loop" ? (
          <LoopGroup command={command} item={item} key={item.loopId} payload={payload} />
        ) : (
          <DisplayStepCard command={command} item={item} key={displayStepItemKey(item)} numberLabel={index + 1} payload={payload} />
        ))}
      </div>
    </section>
  )
}

function workflowBranchDivergence(workflow: JobWorkflow): BranchDivergence | null {
  const artifacts = workflow.artifacts || {}
  if (artifacts.branch_divergence_recovery) return null
  const raw = artifacts.branch_divergence
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return null

  const row = raw as Record<string, unknown>
  return {
    branch: typeof row.branch === "string" ? row.branch : "",
    remote_sha: typeof row.remote_sha === "string" ? row.remote_sha : null,
    local_sha: typeof row.local_sha === "string" ? row.local_sha : null,
    detected_at: typeof row.detected_at === "string" ? row.detected_at : null,
    message: typeof row.message === "string" ? row.message : null
  }
}

function BranchDivergencePanel({
  divergence,
  workflow,
  payload,
  command,
  prefix
}: {
  divergence: BranchDivergence
  workflow: JobWorkflow
  payload: JobDetailPayload
  command: ReturnType<typeof useJobCommand>
  prefix: string
}) {
  const { t } = useT("jobs")
  const sourcePath = withRoutePrefix(`/jobs/${payload.job.id}/source`, prefix)
  const branch = divergence.branch || t("workflow_pr_branch_fallback")

  return (
    <div className="mt-4 rounded border border-amber-200 bg-amber-50 p-3 text-sm text-amber-950 dark:border-amber-900/60 dark:bg-amber-950/30 dark:text-amber-100">
      <div className="font-semibold">{t("workflow_divergence_title")}</div>
      <p className="mt-1 text-amber-900 dark:text-amber-200">
        {t("workflow_divergence_review")}
      </p>
      <dl className="mt-2 grid gap-1 text-xs text-amber-900 dark:text-amber-200 sm:grid-cols-3">
        <div><dt className="font-semibold uppercase tracking-wide">{t("workflow_divergence_branch")}</dt><dd className="font-mono">{branch}</dd></div>
        <div><dt className="font-semibold uppercase tracking-wide">{t("workflow_divergence_remote")}</dt><dd className="font-mono">{shortSha(divergence.remote_sha)}</dd></div>
        <div><dt className="font-semibold uppercase tracking-wide">{t("workflow_divergence_local")}</dt><dd className="font-mono">{shortSha(divergence.local_sha)}</dd></div>
      </dl>
      <div className="mt-3 flex flex-wrap gap-2">
        <Link className={buttonClass("secondary")} to={sourcePath}>{t("workflow_open_source")}</Link>
        <CommandButton command={command} input={{ method: "post", path: payload.paths.app_run_again_path }} tone="secondary">
          {t("workflow_retry_from_pr")}
        </CommandButton>
        <CommandButton command={command} input={{ method: "post", path: workflow.app_force_push_branch_path, confirm: t("workflow_replace_confirm", { branch }) }} tone="danger">
          {t("workflow_replace_pr_branch")}
        </CommandButton>
        <CommandButton command={command} input={{ method: "post", path: workflow.app_discard_branch_output_path }} tone="secondary">
          {t("workflow_discard_stale")}
        </CommandButton>
      </div>
    </div>
  )
}

function shortSha(sha: string | null) {
  return sha ? sha.slice(0, 7) : "unknown"
}

function LoopGroup({ item, payload, command }: { item: LoopStepItem; payload: JobDetailPayload; command: ReturnType<typeof useJobCommand> }) {
  const { t } = useT("jobs")
  const [open, setOpen] = useState(false)
  const status = loopDisplayStatus(item)

  return (
    <section className="border-b border-gray-200 last:border-b-0 dark:border-gray-700">
      <button
        aria-expanded={open}
        className="flex w-full items-center justify-between gap-3 bg-violet-50 px-3 py-2 text-left hover:bg-violet-100 focus:outline-none focus-visible:ring-2 focus-visible:ring-blue-500 dark:bg-violet-950/30 dark:hover:bg-violet-950/50"
        onClick={() => setOpen((current) => !current)}
        type="button"
      >
        <span className="flex min-w-0 items-center gap-2">
          <span className="font-medium text-gray-900 dark:text-gray-100">{loopDisplayName(item, t)}</span>
          <SmallPill>{t("loop_iteration_count", { count: item.iterations.length })}</SmallPill>
        </span>
        <span className="flex shrink-0 items-center gap-2">
          {status ? <StatusPill state={status} /> : null}
          <span aria-hidden="true" className="text-gray-400 dark:text-gray-500">{open ? "−" : "+"}</span>
        </span>
      </button>
      {open ? (
        <div className="space-y-3 border-t border-violet-100 bg-white p-3 dark:border-violet-900/60 dark:bg-gray-950">
          {item.iterations.map((iteration) => (
            <section className="overflow-hidden rounded border border-gray-200 dark:border-gray-700" key={iteration.iteration}>
              <div className="border-b border-gray-200 bg-gray-50 px-3 py-2 text-xs font-semibold uppercase text-gray-500 dark:border-gray-700 dark:bg-gray-800 dark:text-gray-400">
                {t("loop_iteration", { n: iteration.iteration })}
              </div>
              {iteration.items.map((stepItem, index) => (
                <DisplayStepCard command={command} item={stepItem} key={displayStepItemKey(stepItem)} numberLabel={index + 1} payload={payload} />
              ))}
            </section>
          ))}
        </div>
      ) : null}
    </section>
  )
}

function DisplayStepCard({ item, payload, command, numberLabel }: { item: DisplayStepItem; payload: JobDetailPayload; command: ReturnType<typeof useJobCommand>; numberLabel: number | string }) {
  if (item.type === "grade") return <GradeGroup command={command} item={item} numberLabel={numberLabel} payload={payload} />

  return <StepCard command={command} numberLabel={numberLabel} payload={payload} step={item.step} />
}

function GradeGroup({ item, payload, command, numberLabel }: { item: GradeStepItem; payload: JobDetailPayload; command: ReturnType<typeof useJobCommand>; numberLabel: number | string }) {
  const { t } = useT("jobs")
  const [open, setOpen] = useState(false)
  const status = gradeDisplayStatus(item)
  const phases = gradePhases(item, t)
  const summaries = gradeSummaries(item)

  return (
    <div className="border-b border-gray-200 bg-white last:border-b-0 dark:border-gray-700 dark:bg-gray-900">
      <button
        aria-expanded={open}
        className="flex w-full items-center justify-between gap-3 bg-violet-50/50 px-3 py-2 text-left hover:bg-violet-50 focus:outline-none focus-visible:ring-2 focus-visible:ring-blue-500 dark:bg-violet-950/20 dark:hover:bg-violet-950/40"
        onClick={() => setOpen((current) => !current)}
        type="button"
      >
        <span className="flex min-w-0 items-center gap-2">
          <span className="w-6 shrink-0 text-right font-mono text-xs text-gray-400 dark:text-gray-500">{numberLabel}.</span>
          <span className="truncate text-sm font-medium text-gray-900 dark:text-gray-100">{t("grade_label")}</span>
          {item.graders.length > 0 ? <SmallPill>{t("grade_check_count", { count: item.graders.length })}</SmallPill> : null}
          {summaries.length > 0 ? <GradeSummaryPills summaries={summaries} /> : null}
        </span>
        <span className="flex shrink-0 items-center gap-2">
          {status ? <StatusPill state={status} /> : null}
          <span aria-hidden="true" className="text-gray-400 dark:text-gray-500">{open ? "−" : "+"}</span>
        </span>
      </button>
      {open ? (
        <div className="border-t border-violet-100 bg-violet-50/20 p-3 dark:border-violet-900/60 dark:bg-violet-950/10">
          <div className="overflow-hidden rounded border border-violet-100 bg-white dark:border-gray-700 dark:bg-gray-900">
            {phases.map((phase, index) => (
              <StepCard
                command={command}
                displayName={phase.displayName}
                key={phase.step.id}
                metadataLabel={phase.metadataLabel}
                numberLabel={index + 1}
                payload={payload}
                step={phase.step}
              />
            ))}
          </div>
        </div>
      ) : null}
    </div>
  )
}

type GradeSummary = {
  name: string
  status: "passed" | "failed" | "error" | "running" | "queued" | "cancelled" | "unknown"
  required: boolean | null
  exitCode: number | null
  duration: number | null
  logBytes: number | null
}

function GradeSummaryPills({ summaries }: { summaries: GradeSummary[] }) {
  const { t } = useT("jobs")
  const counts = gradeSummaryCounts(summaries)
  return (
    <span className="hidden items-center gap-1 sm:inline-flex">
      {counts.passed > 0 ? <SmallPill>{t("grade_passed", { count: counts.passed })}</SmallPill> : null}
      {counts.failed > 0 ? <SmallPill>{t("grade_failed", { count: counts.failed })}</SmallPill> : null}
      {counts.error > 0 ? <SmallPill>{t("grade_error", { count: counts.error })}</SmallPill> : null}
    </span>
  )
}

const GRADER_DESCRIPTION_LIMIT = 220

// Compact, human-friendly view of a grader Step's details: whether it's
// required, its description (collapsed with "Read more" when long), and the
// command. The raw fields (output, log_path, exit_code, duration_s,
// log_bytes, timeout_minutes) are intentionally hidden — the grade log
// button on the run exposes the output.
function GraderDetails({ details }: { details: Record<string, unknown> }) {
  const { t } = useT("jobs")
  const [expanded, setExpanded] = useState(false)
  const description = (stringValue(details.description) || "").replace(/\s+/g, " ").trim()
  const command = (stringValue(details.command) || "").trim()
  const required = booleanValue(details.required)
  const isLong = description.length > GRADER_DESCRIPTION_LIMIT
  const shownDescription = expanded || !isLong ? description : `${description.slice(0, GRADER_DESCRIPTION_LIMIT).trimEnd()}…`

  return (
    <div className="mt-2 space-y-2 text-xs">
      <SmallPill>{required === false ? t("grader_optional") : t("grader_required")}</SmallPill>
      {description ? (
        <p className="text-gray-700 dark:text-gray-300">
          {shownDescription}
          {isLong ? (
            <button
              className="ml-1 font-medium text-blue-600 hover:text-blue-500 focus:outline-none focus-visible:ring-2 focus-visible:ring-blue-500"
              onClick={() => setExpanded((current) => !current)}
              type="button"
            >
              {expanded ? t("grader_read_less") : t("grader_read_more")}
            </button>
          ) : null}
        </p>
      ) : (
        <p className="italic text-gray-400 dark:text-gray-500">{t("grader_no_description")}</p>
      )}
      {command ? (
        <div>
          <div className="mb-1 font-medium uppercase tracking-wide text-gray-400 dark:text-gray-500">{t("grader_command_label")}</div>
          <pre className="overflow-x-auto rounded bg-white p-2 font-mono text-[11px] text-gray-700 dark:bg-gray-950 dark:text-gray-300">{command}</pre>
        </div>
      ) : null}
    </div>
  )
}

function StepCard({ step, payload, command, numberLabel, displayName, metadataLabel }: { step: JobStep; payload: JobDetailPayload; command: ReturnType<typeof useJobCommand>; numberLabel: number | string; displayName?: string; metadataLabel?: string }) {
  const { t } = useT("jobs")
  const [open, setOpen] = useState(false)
  const runs = sortedRunsNewestFirst(step.runs)
  const activeRun = runs.find((run) => isActiveState(run.state))
  const displayStatus = activeRun ? activeRun.state : step.display_status
  const prepareFailure = prepareFailureDetails(step)

  return (
    <div className="border-b border-gray-200 bg-white last:border-b-0 dark:border-gray-700 dark:bg-gray-900">
      <button
        aria-expanded={open}
        className="flex w-full items-center justify-between gap-3 px-3 py-2 text-left hover:bg-gray-50 focus:outline-none focus-visible:ring-2 focus-visible:ring-blue-500 dark:hover:bg-gray-800"
        onClick={() => setOpen((current) => !current)}
        type="button"
      >
        <span className="flex min-w-0 items-center gap-2">
          <span className="w-6 shrink-0 text-right font-mono text-xs text-gray-400 dark:text-gray-500">{numberLabel}.</span>
          <span className="truncate text-sm font-medium text-gray-900 dark:text-gray-100">{displayName || step.display_name}</span>
        </span>
        <span className="flex shrink-0 items-center gap-2">
          {displayStatus ? <StatusPill state={displayStatus} /> : null}
          <span aria-hidden="true" className="text-gray-400 dark:text-gray-500">{open ? "−" : "+"}</span>
        </span>
      </button>
      {open ? (
        <div className="border-t border-gray-100 bg-gray-50 p-3 dark:border-gray-800 dark:bg-gray-950">
          <div className="flex flex-wrap items-center gap-2 text-xs text-gray-500 dark:text-gray-400">
            <span>{metadataLabel || step.kind}</span>
            {step.loop_id ? <span>{t("step_metadata_iteration", { n: step.iteration ?? 1 })}</span> : null}
            {activeRun && step.state !== activeRun.state ? <SmallPill>{t("step_state_display", { state: step.state.replaceAll("_", " ") })}</SmallPill> : null}
            {step.latest ? <SmallPill>{t("step_latest")}</SmallPill> : null}
            <span>{formatDate(step.started_at || step.created_at)}</span>
          </div>
          {activeRun ? <ActiveRunBanner run={activeRun} /> : null}
          {prepareFailure ? <PrepareFailurePanel failure={prepareFailure} /> : null}
          {step.details && !prepareFailure ? (
            step.kind === "grader"
              ? <GraderDetails details={objectDetails(step.details)} />
              : <pre className="mt-2 overflow-x-auto rounded bg-white p-2 text-xs text-gray-600 dark:bg-gray-900 dark:text-gray-300">{stringify(step.details)}</pre>
          ) : null}
          {runs.length > 0 ? (
            <div className="mt-3 space-y-2">
              {runs.map((run) => <RunRow active={activeRun?.id === run.id} command={command} key={run.id} payload={payload} run={run} />)}
            </div>
          ) : <p className="mt-2 text-xs text-gray-400 dark:text-gray-500">{t("section_no_runs")}</p>}
        </div>
      ) : null}
    </div>
  )
}

function PrepareFailurePanel({ failure }: { failure: PrepareFailure }) {
  const { t } = useT("jobs")
  const status = prepareFailureStatus(failure, t)

  return (
    <section className="mt-2 rounded border border-amber-200 bg-amber-50 p-3 text-xs text-amber-900 dark:border-amber-900/70 dark:bg-amber-950/40 dark:text-amber-200">
      <div className="font-semibold">
        {failure.soft ? t("prepare_failure_soft_title") : t("prepare_failure_hard_title")}
      </div>
      {failure.soft ? (
        <p className="mt-1">
          {t("prepare_failure_soft_body")} <code className="font-mono">{t("prepare_failure_soft_syrus_yml")}</code> <code className="font-mono">{t("prepare_failure_soft_prepare")}</code> {t("prepare_failure_soft_suffix")}
        </p>
      ) : null}
      <dl className="mt-2 grid gap-x-4 gap-y-1 md:grid-cols-[max-content_1fr]">
        <dt className="font-medium">{t("prepare_failure_command")}</dt>
        <dd className="min-w-0 break-words font-mono">{failure.command || "-"}</dd>
        <dt className="font-medium">{t("prepare_failure_workdir")}</dt>
        <dd className="min-w-0 break-words font-mono">{failure.workdir || "-"}</dd>
        <dt className="font-medium">{t("prepare_failure_status_label")}</dt>
        <dd>{status}</dd>
      </dl>
      {failure.output_tail ? (
        <pre className="mt-3 max-h-64 overflow-auto rounded border border-amber-200 bg-white/70 p-2 font-mono text-[11px] text-amber-950 whitespace-pre-wrap dark:border-amber-800 dark:bg-gray-950 dark:text-amber-100">{failure.output_tail}</pre>
      ) : null}
    </section>
  )
}

function RunRow({ run, payload, command, active = false }: { run: JobRun; payload: JobDetailPayload; command: ReturnType<typeof useJobCommand>; active?: boolean }) {
  const { t } = useT("jobs")
  const [gradeLogOpen, setGradeLogOpen] = useState(false)
  const [artifactView, setArtifactView] = useState<"transcript" | "diff" | null>(null)
  const gradeLog = useMutation({
    mutationFn: (path: string) => fetchJobGradeLog(path),
    onSuccess: () => {
      setArtifactView(null)
      setGradeLogOpen(true)
    }
  })
  const artifacts = useQuery({
    queryKey: ["job_run_artifacts", String(payload.job.id), String(run.id)],
    queryFn: () => fetchJobRunArtifacts(run.app_artifacts_path),
    enabled: artifactView != null,
    refetchInterval: artifactView === "transcript" && isActiveState(run.state) ? 2000 : false
  })
  const artifactsLoading = artifacts.isFetching && !artifacts.data

  function showArtifacts(view: "transcript" | "diff") {
    setGradeLogOpen(false)
    setArtifactView((current) => current === view ? null : view)
  }

  function showGradeLog(path: string) {
    setArtifactView(null)
    if (gradeLogOpen) {
      setGradeLogOpen(false)
    } else if (gradeLog.data) {
      setGradeLogOpen(true)
    } else {
      gradeLog.mutate(path)
    }
  }

  return (
    <div className={`rounded border bg-white p-3 text-sm dark:bg-gray-900 ${active ? "border-blue-300 ring-1 ring-blue-100 dark:border-blue-700 dark:ring-blue-900/70" : "border-gray-200 dark:border-gray-700"}`}>
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <div className="flex flex-wrap items-center gap-2">
            <span className="font-medium text-gray-900 dark:text-gray-100">{t("run_number", { id: run.id })}</span>
            <StatusPill state={run.state} />
            {run.rate_limited ? <SmallPill>{t("run_rate_limited")}</SmallPill> : null}
          </div>
          <p className="mt-1 text-xs text-gray-500 dark:text-gray-400">
            {run.agent_provider || t("run_agent_fallback")} · {t("run_turns", { count: run.agent_turns ?? 0 })} · {run.job_log_count} {t("run_log_line", { count: run.job_log_count })} · {formatCurrency(run.cost_usd || 0)}
          </p>
          {run.agent_summary ? <p className="mt-2 whitespace-pre-wrap text-gray-700 dark:text-gray-300">{run.agent_summary}</p> : null}
          {run.health_snapshots.at(-1) ? <p className="mt-2 text-xs text-gray-500 dark:text-gray-400">{t("run_health")} {run.health_snapshots.at(-1)?.health_status || "unknown"} {run.health_snapshots.at(-1)?.hint ? `- ${run.health_snapshots.at(-1)?.hint}` : ""}</p> : null}
          {run.failure_classification ? <p className="mt-1 text-xs text-gray-600 dark:text-gray-300">{t("run_failure_label")} {humanize(run.failure_classification.classification)} · {run.failure_classification.retryable ? t("run_retryable") : t("run_not_retryable")}{run.failure_classification.reason ? ` - ${run.failure_classification.reason}` : ""}</p> : null}
          {run.run_diagnostic?.present ? <p className="mt-1 text-xs text-amber-700 dark:text-amber-300">{t("run_diagnostic_captured")} {formatDate(run.run_diagnostic.created_at)}{run.run_diagnostic.error_message ? `: ${run.run_diagnostic.error_message}` : ""}</p> : null}
        </div>
        <div className="flex flex-wrap justify-end gap-2">
          {run.job_log_count > 0 ? (
            <button className={buttonClass("secondary")} disabled={artifactsLoading} onClick={() => showArtifacts("transcript")} type="button">
              {artifactsLoading && artifactView === "transcript" ? t("run_loading") : t("run_transcript")}
            </button>
          ) : null}
          {run.agent_diff_present ? (
            <button className={buttonClass("secondary")} disabled={artifactsLoading} onClick={() => showArtifacts("diff")} type="button">
              {artifactsLoading && artifactView === "diff" ? t("run_loading") : t("run_diff")}
            </button>
          ) : null}
          {run.can_stop ? <CommandButton command={command} input={{ method: "post", path: run.app_stop_path }} tone="danger">{t("run_stop")}</CommandButton> : null}
          {run.can_diagnose ? <CommandButton command={command} input={{ method: "post", path: run.app_diagnose_path }} tone="secondary">{t("run_diagnose")}</CommandButton> : null}
          {run.can_resume ? <CommandButton command={command} input={{ method: "post", path: payload.paths.app_resume_path, body: { source_run_id: run.id } }} tone="secondary">{t("run_resume")}</CommandButton> : null}
          {run.app_grade_log_path ? (
            <button className={buttonClass("secondary")} disabled={gradeLog.isPending} onClick={() => showGradeLog(run.app_grade_log_path!)} type="button">
              {gradeLog.isPending ? t("run_loading_log") : t("run_grade_log")}
            </button>
          ) : null}
        </div>
      </div>
      {artifacts.isError ? <p className="mt-3 text-xs text-red-700 dark:text-red-300">{errorMessage(artifacts.error, t("run_artifacts_error"))}</p> : null}
      {artifactView && artifacts.data ? <RunArtifactsPanel onClose={() => setArtifactView(null)} payload={artifacts.data} view={artifactView} /> : null}
      {gradeLog.isError ? <p className="mt-3 text-xs text-red-700 dark:text-red-300">{errorMessage(gradeLog.error, t("run_grade_log_error"))}</p> : null}
      {gradeLogOpen && gradeLog.data ? (
        <RunGradeLogPanel onClose={() => setGradeLogOpen(false)} payload={gradeLog.data} />
      ) : null}
    </div>
  )
}

function RunArtifactsPanel({ payload, view, onClose }: { payload: Awaited<ReturnType<typeof fetchJobRunArtifacts>>; view: "transcript" | "diff"; onClose: () => void }) {
  const { t } = useT("jobs")
  if (view === "diff") {
    return (
      <section className={artifactPanelClass()}>
        <ArtifactPanelHeader onClose={onClose}>{t("artifact_header_diff")}</ArtifactPanelHeader>
        {payload.agent_diff ? (
          <AgentDiff diff={payload.agent_diff} />
        ) : <p className="p-3 text-sm text-gray-400 dark:text-gray-500">{t("artifact_no_diff")}</p>}
      </section>
    )
  }

  return (
    <section className={artifactPanelClass()}>
      <ArtifactPanelHeader onClose={onClose}>{t("artifact_header_transcript")}</ArtifactPanelHeader>
      {payload.logs.length > 0 ? <RunTranscriptLogs logs={payload.logs} /> : <p className="p-3 text-sm text-gray-400 dark:text-gray-500">{t("artifact_no_transcript")}</p>}
    </section>
  )
}

function RunGradeLogPanel({ payload, onClose }: { payload: Awaited<ReturnType<typeof fetchJobGradeLog>>; onClose: () => void }) {
  const { t } = useT("jobs")
  return (
    <section className={artifactPanelClass()}>
      <ArtifactPanelHeader onClose={onClose}>{payload.name || t("run_number", { id: payload.run_id })} {t("artifact_grade_log_title")}</ArtifactPanelHeader>
      <pre className="max-h-96 overflow-auto bg-white p-3 font-mono text-xs text-gray-800 whitespace-pre-wrap max-md:min-h-0 max-md:flex-1 max-md:max-h-none dark:bg-gray-950 dark:text-gray-200" data-testid="run-grade-log-stream"><AnsiText text={payload.contents} /></pre>
    </section>
  )
}

function artifactPanelClass() {
  return "mt-3 rounded border border-gray-200 bg-gray-50 max-md:fixed max-md:inset-0 max-md:z-50 max-md:mt-0 max-md:flex max-md:h-[100dvh] max-md:flex-col max-md:rounded-none max-md:border-0 max-md:bg-white dark:border-gray-700 dark:bg-gray-950 max-md:dark:bg-gray-950"
}

function ArtifactPanelHeader({ children, onClose }: { children: ReactNode; onClose: () => void }) {
  const { t } = useT("jobs")
  return (
    <div className="flex shrink-0 items-center justify-between gap-3 border-b border-gray-200 px-3 py-2 dark:border-gray-700">
      <h4 className="text-xs font-semibold uppercase text-gray-500 dark:text-gray-400">{children}</h4>
      <button aria-label={t("artifact_close")} className="hidden rounded p-2 text-gray-500 hover:bg-gray-100 hover:text-gray-700 max-md:block dark:text-gray-400 dark:hover:bg-gray-800 dark:hover:text-gray-200" onClick={onClose} type="button">
        <CloseIcon className="h-5 w-5" />
      </button>
    </div>
  )
}

type DiffLineKind = "file" | "meta" | "hunk" | "add" | "delete" | "context"
type DiffLine = {
  kind: DiffLineKind
  oldLine: number | null
  newLine: number | null
  marker: string
  code: string
}

type LineAnnotation = "covered" | "uncovered" | "not_executable"

function AgentDiff({ diff, annotations }: { diff: string; annotations?: Record<string, LineAnnotation> }) {
  const lines = parseUnifiedDiff(diff)

  return (
    <div className="max-h-[32rem] overflow-auto bg-white font-mono text-xs max-md:min-h-0 max-md:flex-1 max-md:max-h-none dark:bg-gray-950" data-testid="agent-diff-viewer">
      <table className="min-w-full border-separate border-spacing-0">
        <tbody>
          {lines.map((line, index) => {
            const annotation = annotations && line.newLine != null ? annotations[String(line.newLine)] : undefined
            return (
              <tr
                className={diffLineClass(line.kind)}
                data-coverage={annotation}
                data-diff-kind={line.kind}
                key={`${index}-${line.kind}-${line.oldLine || ""}-${line.newLine || ""}`}
              >
                <td className={diffGutterClass(line.kind)}>{line.oldLine ?? ""}</td>
                <td className={diffGutterClass(line.kind)}>{line.newLine ?? ""}</td>
                <td className={diffMarkerClass(line.kind)}>{line.marker}</td>
                <td className={`min-w-[40rem] whitespace-pre px-3 py-0.5 text-gray-900 dark:text-gray-200 ${diffCoverageBorderClass(annotation)}`}>{line.code || " "}</td>
                <td className="w-4 select-none px-1 text-center">
                  {annotation === "covered" ? <span className="text-emerald-600 dark:text-emerald-400">✓</span>
                    : annotation === "uncovered" ? <span className="text-red-600 dark:text-red-400">✗</span>
                    : null}
                </td>
              </tr>
            )
          })}
        </tbody>
      </table>
    </div>
  )
}

function diffCoverageBorderClass(annotation: LineAnnotation | undefined) {
  if (annotation === "covered") return "border-l-2 border-emerald-500"
  if (annotation === "uncovered") return "border-l-2 border-red-500"
  return ""
}

function parseUnifiedDiff(diff: string) {
  const rawLines = diff.replace(/\r\n/g, "\n").split("\n")
  if (rawLines.at(-1) === "") rawLines.pop()

  const lines: DiffLine[] = []
  let oldLine: number | null = null
  let newLine: number | null = null

  for (const rawLine of rawLines) {
    const hunk = rawLine.match(/^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/)
    if (hunk) {
      oldLine = Number(hunk[1])
      newLine = Number(hunk[2])
      lines.push(diffLine("hunk", rawLine))
      continue
    }

    if (rawLine.startsWith("diff --git ")) {
      lines.push(diffLine("file", rawLine))
    } else if (rawLine.startsWith("+") && !rawLine.startsWith("+++")) {
      lines.push(diffLine("add", rawLine.slice(1), null, newLine, "+"))
      if (newLine !== null) newLine += 1
    } else if (rawLine.startsWith("-") && !rawLine.startsWith("---")) {
      lines.push(diffLine("delete", rawLine.slice(1), oldLine, null, "-"))
      if (oldLine !== null) oldLine += 1
    } else if (rawLine.startsWith(" ") && oldLine !== null && newLine !== null) {
      lines.push(diffLine("context", rawLine.slice(1), oldLine, newLine))
      oldLine += 1
      newLine += 1
    } else {
      lines.push(diffLine("meta", rawLine))
    }
  }

  return lines
}

function diffLine(kind: DiffLineKind, code: string, oldLine: number | null = null, newLine: number | null = null, marker = "") {
  return { kind, oldLine, newLine, marker, code }
}

function diffLineClass(kind: DiffLineKind) {
  switch (kind) {
    case "add": return "bg-green-50 dark:bg-green-950/40"
    case "delete": return "bg-red-50 dark:bg-red-950/40"
    case "hunk": return "bg-blue-50 text-blue-800 dark:bg-blue-950/50 dark:text-blue-200"
    case "file": return "bg-gray-100 font-semibold dark:bg-gray-800 dark:text-gray-100"
    case "meta": return "bg-gray-50 text-gray-500 dark:bg-gray-900 dark:text-gray-400"
    default: return "bg-white dark:bg-gray-950"
  }
}

function diffGutterClass(kind: DiffLineKind) {
  const base = "w-12 select-none border-r px-2 py-0.5 text-right text-gray-400"
  switch (kind) {
    case "add": return `${base} border-green-200 bg-green-100 text-green-700 dark:border-green-900 dark:bg-green-950/60 dark:text-green-300`
    case "delete": return `${base} border-red-200 bg-red-100 text-red-700 dark:border-red-900 dark:bg-red-950/60 dark:text-red-300`
    case "hunk": return `${base} border-blue-200 bg-blue-100 text-blue-700 dark:border-blue-900 dark:bg-blue-950/60 dark:text-blue-300`
    default: return `${base} border-gray-200 bg-gray-50 dark:border-gray-800 dark:bg-gray-900 dark:text-gray-500`
  }
}

function diffMarkerClass(kind: DiffLineKind) {
  const base = "w-6 select-none px-2 py-0.5 text-center"
  switch (kind) {
    case "add": return `${base} text-green-700`
    case "delete": return `${base} text-red-700`
    case "hunk": return `${base} text-blue-700`
    default: return `${base} text-gray-300`
  }
}

function RunTranscriptLogs({ logs }: { logs: Awaited<ReturnType<typeof fetchJobRunArtifacts>>["logs"] }) {
  const { t } = useT("jobs")
  const listRef = useRef<HTMLOListElement | null>(null)
  const atBottomRef = useRef(true)
  const logSignature = logs.map((log) => `${log.id}:${log.sequence}:${log.kind || ""}:${log.chunk.length}`).join("|")
  const displayLogs = coalesceTranscriptLogs(logs)

  function handleScroll(event: UIEvent<HTMLOListElement>) {
    atBottomRef.current = isRunTranscriptAtBottom(event.currentTarget)
  }

  useLayoutEffect(() => {
    if (atBottomRef.current) scrollRunTranscriptToBottom(listRef.current)
  }, [logSignature])

  return (
    <ol className="max-h-[32rem] overflow-auto divide-y divide-gray-200 max-md:min-h-0 max-md:flex-1 max-md:max-h-none dark:divide-gray-800" data-testid="run-transcript-log-stream" onScroll={handleScroll} ref={listRef}>
      {displayLogs.map((log) => (
        <li className="grid gap-2 px-3 py-2 font-mono text-xs text-gray-800 sm:grid-cols-[5rem_minmax(0,1fr)] dark:text-gray-200" key={log.id}>
          <span className="text-gray-400 dark:text-gray-500">{transcriptLogKindLabel(log.kind, t) || `#${log.sequence}`}</span>
          <pre className="whitespace-pre-wrap break-words"><AnsiText text={log.chunk} /></pre>
        </li>
      ))}
    </ol>
  )
}

type TranscriptLog = Awaited<ReturnType<typeof fetchJobRunArtifacts>>["logs"][number]
type DisplayTranscriptLog = TranscriptLog & { sourceKey: string }

function coalesceTranscriptLogs(logs: TranscriptLog[]) {
  const displayLogs: DisplayTranscriptLog[] = []
  const sourceByKind = new Map<string, string>()

  for (const log of logs) {
    const displayLog = { ...log, sourceKey: transcriptLogSourceKey(log, sourceByKind) }
    const previous = displayLogs.at(-1)
    if (previous && shouldCoalesceTranscriptLogs(previous, displayLog)) {
      previous.chunk = joinTranscriptChunks(previous.chunk, displayLog.chunk)
      continue
    }

    displayLogs.push(displayLog)
  }

  return displayLogs
}

function transcriptLogSourceKey(log: TranscriptLog, sourceByKind: Map<string, string>) {
  const kind = log.kind || "log"
  const command = commandMarkerSource(log.chunk)
  if (command) {
    const source = `${kind}:command:${command}`
    sourceByKind.set(kind, source)
    return source
  }

  return sourceByKind.get(kind) || `${kind}:run`
}

function commandMarkerSource(chunk: string) {
  const firstLine = chunk.split(/\r?\n/, 1)[0]?.trim() || ""
  const marker = firstLine.match(/^\[(prepare|grade|grader:[^\]]+)\](?: \(\d+\/\d+\))? \$ (.+)$/)
  if (!marker) return null

  return `${marker[1]}:${marker[2]}`
}

function shouldCoalesceTranscriptLogs(previous: DisplayTranscriptLog, next: DisplayTranscriptLog) {
  if (previous.kind !== next.kind) return false
  if (previous.sourceKey !== next.sourceKey) return false
  return !["tool_call", "rate_limited"].includes(previous.kind || "")
}

function joinTranscriptChunks(previous: string, next: string) {
  if (previous.endsWith("\n") || next.startsWith("\n")) return previous + next
  return `${previous}\n${next}`
}

function isRunTranscriptAtBottom(element: HTMLElement) {
  return element.scrollHeight - element.scrollTop - element.clientHeight <= RUN_TRANSCRIPT_BOTTOM_THRESHOLD_PX
}

function scrollRunTranscriptToBottom(element: HTMLElement | null) {
  if (!element) return
  element.scrollTop = element.scrollHeight
}

function transcriptLogKindLabel(kind: string | null | undefined, t: ReturnType<typeof useT>["t"]) {
  if (kind === "assistant_text") return t("transcript_kind_agent")
  if (kind === "tool_call") return t("transcript_kind_tool")
  if (kind === "system") return t("transcript_kind_system")
  return kind
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

function AttachmentCard({ attachment }: { attachment: JobAttachment }) {
  const { t } = useT("jobs")
  const title = attachment.title || attachment.filename || attachment.google_doc_url || `Attachment #${attachment.id}`
  return (
    <article className="rounded border border-gray-200 bg-white p-3 text-sm dark:border-gray-700 dark:bg-gray-900">
      <div className="font-medium text-gray-900 dark:text-gray-100">{attachment.file_path ? <a className="hover:underline" href={attachment.file_path}>{title}</a> : title}</div>
      <div className="mt-1 text-xs text-gray-500 dark:text-gray-400">
        {attachment.google_doc_url ? <a className="text-blue-600 hover:underline" href={attachment.google_doc_url} rel="noopener" target="_blank">{t("attachment_google_doc")}</a> : attachment.content_type || attachment.attachment_type}
        {attachment.byte_size ? ` · ${formatBytes(attachment.byte_size)}` : ""}
      </div>
    </article>
  )
}

function SourceTab({ jobId, coverageInfo }: { jobId: string; coverageInfo: { workflowId: number; coverage: CoverageArtifact } | null }) {
  const [mode, setMode] = useState<"browse" | "diff">("browse")
  const [sourceRef, setSourceRef] = useState<string | null>(null)
  const [sourcePath, setSourcePath] = useState<string | null>(null)
  const [diffBaseRef, setDiffBaseRef] = useState<string | null>(null)
  const [diffHeadRef, setDiffHeadRef] = useState<string | null>(null)
  const [expandedPaths, setExpandedPaths] = useState<Set<string>>(() => new Set())
  const search = sourceSearch(sourceRef, sourcePath)
  const diffSearch = sourceDiffSearch(diffBaseRef, diffHeadRef)
  const source = useQuery({
    queryKey: ["jobs", jobId, "source", search],
    queryFn: () => fetchJobSource(jobId, search),
    placeholderData: keepPreviousData
  })
  const sourceDiff = useQuery({
    enabled: mode === "diff",
    queryKey: ["jobs", jobId, "source_diff", diffSearch],
    queryFn: () => fetchJobSourceDiff(jobId, diffSearch)
  })

  const { t } = useT("jobs")

  const diffAnnotations = coverageInfo?.coverage.diff_annotations ?? null
  const hitMapAttached = Boolean(coverageInfo?.coverage.hit_map_attached)
  const coverageWorkflowId = coverageInfo?.workflowId ?? null

  if (source.isPending) return <PanelMessage>{t("source_loading")}</PanelMessage>
  if (source.isError) return <PanelMessage tone="error">{errorMessage(source.error, t("source_error"))}</PanelMessage>

  if (mode === "diff") {
    if (sourceDiff.isPending) {
      return <SourceShell mode={mode} onModeChange={setMode} showDiffToggle={source.data.branch_commits.length > 0}><PanelMessage>{t("source_diff_loading")}</PanelMessage></SourceShell>
    }
    if (sourceDiff.isError) {
      return <SourceShell mode={mode} onModeChange={setMode} showDiffToggle={source.data.branch_commits.length > 0}><PanelMessage tone="error">{errorMessage(sourceDiff.error, t("source_diff_error"))}</PanelMessage></SourceShell>
    }

    return <SourceDiffBrowser diffAnnotations={diffAnnotations} mode={mode} onModeChange={setMode} onSelectBaseRef={setDiffBaseRef} onSelectHeadRef={setDiffHeadRef} payload={sourceDiff.data} showDiffToggle={source.data.branch_commits.length > 0} />
  }

  return <SourceBrowser coverageWorkflowId={coverageWorkflowId} expandedPaths={expandedPaths} hitMapAttached={hitMapAttached} mode={mode} onModeChange={setMode} payload={source.data} setExpandedPaths={setExpandedPaths} onSelectPath={(path) => {
    setSourceRef(source.data.selected_ref)
    setSourcePath(path)
  }} onSelectRef={(ref) => {
    setSourceRef(ref)
    setSourcePath(null)
  }} showDiffToggle={source.data.branch_commits.length > 0} />
}

function SourceBrowser({
  coverageWorkflowId,
  expandedPaths,
  hitMapAttached,
  mode,
  onModeChange,
  payload,
  setExpandedPaths,
  onSelectPath,
  onSelectRef,
  showDiffToggle
}: {
  coverageWorkflowId: number | null
  expandedPaths: Set<string>
  hitMapAttached: boolean
  mode: "browse" | "diff"
  onModeChange: (mode: "browse" | "diff") => void
  payload: JobSourcePayload
  setExpandedPaths: Dispatch<SetStateAction<Set<string>>>
  onSelectPath: (path: string) => void
  onSelectRef: (ref: string) => void
  showDiffToggle: boolean
}) {
  const { t } = useT("jobs")
  const visibleItems = useMemo(() => payload.tree_items.slice(0, 2000), [payload.tree_items])
  const tree = useMemo(() => buildSourceTree(visibleItems), [visibleItems])
  const refOptions = refOptionsFor(payload, [payload.selected_ref])
  const fileLanguage = payload.file ? sourceLanguage(payload.file.language) : null
  const selectedFilePath = payload.file?.path ?? null

  const hitMap = useQuery({
    enabled: hitMapAttached && coverageWorkflowId != null && selectedFilePath != null,
    queryKey: ["workflow_coverage_hit_map", coverageWorkflowId, selectedFilePath],
    queryFn: () => fetchWorkflowCoverageHitMap(coverageWorkflowId!, selectedFilePath!),
    staleTime: 5 * 60 * 1000
  })

  if (payload.source_error) return <PanelMessage tone="error">{payload.source_error}</PanelMessage>

  function toggleDirectory(path: string) {
    setExpandedPaths((current) => {
      const next = new Set(current)
      if (next.has(path)) {
        next.delete(path)
      } else {
        next.add(path)
      }
      return next
    })
  }

  const hitLines = hitMap.isSuccess && hitMap.data.hit_map_attached ? hitMap.data.lines : null

  return (
    <SourceShell mode={mode} onModeChange={onModeChange} showDiffToggle={showDiffToggle}>
      <div className="flex flex-wrap items-center justify-between gap-3">
        <label className="text-sm text-gray-600 dark:text-gray-300">
          {t("source_viewing_label")}
          <select className="ml-2 rounded border border-gray-300 bg-white px-2 py-1 text-sm text-gray-900 dark:border-gray-700 dark:bg-gray-950 dark:text-gray-100" onChange={(event) => onSelectRef(event.target.value)} value={payload.selected_ref}>
            {refOptions.map((option) => <option key={option.value} value={option.value}>{option.label}</option>)}
          </select>
        </label>
        {payload.tree_truncated ? <span className="text-xs text-amber-700">{t("source_tree_truncated")}</span> : null}
      </div>
      <div className="grid min-h-[36rem] overflow-hidden rounded border border-gray-200 bg-white lg:grid-cols-[20rem_minmax(0,1fr)] dark:border-gray-700 dark:bg-gray-900">
        <div className="max-h-[36rem] overflow-auto border-b border-gray-200 bg-gray-50 lg:border-b-0 lg:border-r dark:border-gray-700 dark:bg-gray-950">
          {tree.length > 0 ? tree.map((node) => (
            <SourceTreeRow
              expandedPaths={expandedPaths}
              key={node.path}
              node={node}
              onSelectPath={onSelectPath}
              onToggleDirectory={toggleDirectory}
              selectedPath={payload.selected_path}
            />
          )) : <p className="p-4 text-sm text-gray-400 dark:text-gray-500">{t("source_no_files")}</p>}
          {payload.tree_items.length > visibleItems.length ? <p className="p-3 text-xs text-amber-700">{t("source_showing_first", { count: visibleItems.length })}</p> : null}
        </div>
        <div className="min-w-0 overflow-auto">
          {payload.file_error ? <p className="p-4 text-sm text-red-700">{payload.file_error}</p> : null}
          {payload.file ? (
            <>
              <div className="sticky top-0 flex items-center gap-3 border-b border-gray-100 bg-gray-50 px-4 py-2 font-mono text-xs text-gray-600 dark:border-gray-800 dark:bg-gray-950 dark:text-gray-400">
                <span className="min-w-0 flex-1 truncate">{payload.file.path}</span>
                <span>{payload.file.language}</span>
                <span>{formatBytes(payload.file.size)}</span>
              </div>
              {hitLines ? (
                <CoverageAnnotatedSource content={payload.file.content} fileLanguage={fileLanguage} hitLines={hitLines} />
              ) : (
                <>
                  {hitMapAttached && !hitMap.isSuccess ? (
                    <p className="px-4 pt-2 text-xs text-gray-400 dark:text-gray-500">{t("source_coverage_loading")}</p>
                  ) : hitMapAttached === false && coverageWorkflowId != null && selectedFilePath != null ? (
                    <p className="px-4 pt-2 text-xs text-gray-400 dark:text-gray-500">{t("source_coverage_expired")}</p>
                  ) : null}
                  <pre className="m-0 overflow-x-auto p-4 text-sm leading-relaxed text-gray-900 dark:text-gray-100">
                    <code>{fileLanguage ? highlightCode(payload.file.content, fileLanguage) : payload.file.content}</code>
                  </pre>
                </>
              )}
            </>
          ) : <div className="flex h-full min-h-[20rem] items-center justify-center p-4 text-sm text-gray-400 dark:text-gray-500">{t("source_select_file")}</div>}
        </div>
      </div>
    </SourceShell>
  )
}

function CoverageAnnotatedSource({ content, fileLanguage, hitLines }: {
  content: string
  fileLanguage: ReturnType<typeof sourceLanguage>
  hitLines: Record<string, number>
}) {
  const lines = content.split("\n")
  return (
    <table className="min-w-full border-separate border-spacing-0 font-mono text-sm" data-testid="coverage-annotated-source">
      <tbody>
        {lines.map((line, i) => {
          const lineNum = i + 1
          const hits = hitLines[String(lineNum)]
          const rowClass = hits === undefined
            ? "bg-white dark:bg-gray-950"
            : hits > 0
            ? "bg-green-50 dark:bg-green-950/30"
            : "bg-red-50 dark:bg-red-950/30"
          return (
            <tr className={rowClass} data-coverage-hits={hits} data-line={lineNum} key={lineNum}>
              <td className="w-4 select-none border-r border-gray-200 px-1 text-right text-xs text-gray-400 dark:border-gray-800 dark:text-gray-500">
                {hits === undefined ? null : hits > 0 ? (
                  <span className="text-emerald-600 dark:text-emerald-400" title={`${hits} hit${hits !== 1 ? "s" : ""}`}>✓</span>
                ) : (
                  <span className="text-red-600 dark:text-red-400" title="not covered">✗</span>
                )}
              </td>
              <td className="w-10 select-none px-2 text-right text-xs text-gray-400 dark:text-gray-600">{lineNum}</td>
              <td className="min-w-[40rem] whitespace-pre px-3 py-0.5 leading-relaxed text-gray-900 dark:text-gray-100">
                {fileLanguage ? highlightCode(line, fileLanguage) : line}
              </td>
            </tr>
          )
        })}
      </tbody>
    </table>
  )
}

function SourceShell({
  children,
  mode,
  onModeChange,
  showDiffToggle
}: {
  children: ReactNode
  mode: "browse" | "diff"
  onModeChange: (mode: "browse" | "diff") => void
  showDiffToggle: boolean
}) {
  const { t } = useT("jobs")
  return (
    <section className="space-y-3">
      {showDiffToggle ? (
        <div className="inline-flex rounded border border-gray-300 bg-white p-0.5 text-sm dark:border-gray-700 dark:bg-gray-950">
          {(["browse", "diff"] as const).map((option) => (
            <button
              className={`rounded px-3 py-1 ${mode === option ? "bg-blue-600 text-white" : "text-gray-600 hover:bg-gray-50 dark:text-gray-300 dark:hover:bg-gray-900"}`}
              key={option}
              onClick={() => onModeChange(option)}
              type="button"
            >
              {option === "browse" ? t("source_browse") : t("source_diff")}
            </button>
          ))}
        </div>
      ) : null}
      {children}
    </section>
  )
}

function SourceDiffBrowser({
  diffAnnotations,
  mode,
  onModeChange,
  onSelectBaseRef,
  onSelectHeadRef,
  payload,
  showDiffToggle
}: {
  diffAnnotations: Record<string, Record<string, LineAnnotation>> | null
  mode: "browse" | "diff"
  onModeChange: (mode: "browse" | "diff") => void
  onSelectBaseRef: (ref: string) => void
  onSelectHeadRef: (ref: string) => void
  payload: JobSourceDiffPayload
  showDiffToggle: boolean
}) {
  const { t } = useT("jobs")
  const [selectedPath, setSelectedPath] = useState<string | null>(null)
  const selectedFile = selectedPath ? payload.files.find((file) => file.path === selectedPath) || null : null
  const refOptions = refOptionsFor(payload, [payload.base_ref, payload.head_ref])

  useEffect(() => {
    if (selectedPath && !payload.files.some((file) => file.path === selectedPath)) setSelectedPath(null)
  }, [payload.files, selectedPath])

  if (payload.diff_error) return <SourceShell mode={mode} onModeChange={onModeChange} showDiffToggle={showDiffToggle}><PanelMessage tone="error">{payload.diff_error}</PanelMessage></SourceShell>

  return (
    <SourceShell mode={mode} onModeChange={onModeChange} showDiffToggle={showDiffToggle}>
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div className="flex flex-wrap items-center gap-3">
          <label className="text-sm text-gray-600 dark:text-gray-300">
            {t("source_from_label")}
            <select className="ml-2 rounded border border-gray-300 bg-white px-2 py-1 text-sm text-gray-900 dark:border-gray-700 dark:bg-gray-950 dark:text-gray-100" onChange={(event) => onSelectBaseRef(event.target.value)} value={payload.base_ref || ""}>
              {refOptions.map((option) => <option key={option.value} value={option.value}>{option.label}</option>)}
            </select>
          </label>
          <label className="text-sm text-gray-600 dark:text-gray-300">
            {t("source_to_label")}
            <select className="ml-2 rounded border border-gray-300 bg-white px-2 py-1 text-sm text-gray-900 dark:border-gray-700 dark:bg-gray-950 dark:text-gray-100" onChange={(event) => onSelectHeadRef(event.target.value)} value={payload.head_ref || ""}>
              {refOptions.map((option) => <option key={option.value} value={option.value}>{option.label}</option>)}
            </select>
          </label>
        </div>
        {payload.truncated ? <span className="text-xs text-amber-700">{t("source_diff_truncated")}</span> : null}
      </div>
      <div className="grid min-h-[36rem] overflow-hidden rounded border border-gray-200 bg-white lg:grid-cols-[20rem_minmax(0,1fr)] dark:border-gray-700 dark:bg-gray-900">
        <div className="max-h-[36rem] overflow-auto border-b border-gray-200 bg-gray-50 lg:border-b-0 lg:border-r dark:border-gray-700 dark:bg-gray-950">
          {payload.files.length > 0 ? payload.files.map((file) => (
            <button
              className={`flex w-full items-center gap-2 px-3 py-1.5 text-left font-mono text-xs hover:bg-blue-50 dark:hover:bg-blue-950/40 ${selectedFile?.path === file.path ? "bg-blue-100 text-blue-700 dark:bg-blue-950/60 dark:text-blue-200" : "text-gray-700 dark:text-gray-300"}`}
              key={file.path}
              onClick={() => setSelectedPath(file.path)}
              title={`${file.path} (+${file.additions} -${file.deletions})`}
              type="button"
            >
              <SourceDiffStatusBadge status={file.status} />
              <span className="min-w-0 flex-1 truncate">{file.path}</span>
            </button>
          )) : <p className="p-4 text-sm text-gray-400 dark:text-gray-500">{t("source_no_changed_files")}</p>}
        </div>
        <div className="min-w-0 overflow-auto">
          {selectedFile ? (
            selectedFile.patch !== null ? (
              <>
                <div className="sticky top-0 flex items-center gap-3 border-b border-gray-100 bg-gray-50 px-4 py-2 font-mono text-xs text-gray-600 dark:border-gray-800 dark:bg-gray-950 dark:text-gray-400">
                  <span className="min-w-0 flex-1 truncate">{selectedFile.path}</span>
                  <span>+{selectedFile.additions}</span>
                  <span>-{selectedFile.deletions}</span>
                </div>
                <AgentDiff annotations={diffAnnotations?.[selectedFile.path]} diff={selectedFile.patch} />
              </>
            ) : <div className="flex h-full min-h-[20rem] items-center justify-center p-4 text-sm text-gray-400 dark:text-gray-500">{t("source_diff_not_available")}</div>
          ) : <div className="flex h-full min-h-[20rem] items-center justify-center p-4 text-sm text-gray-400 dark:text-gray-500">{t("source_select_diff_file")}</div>}
        </div>
      </div>
    </SourceShell>
  )
}

function SourceDiffStatusBadge({ status }: { status: string }) {
  const normalized = status.toLowerCase()
  const styles: Record<string, string> = {
    added: "bg-emerald-100 text-emerald-700 dark:bg-emerald-950/60 dark:text-emerald-200",
    modified: "bg-amber-100 text-amber-700 dark:bg-amber-950/60 dark:text-amber-200",
    removed: "bg-red-100 text-red-700 dark:bg-red-950/60 dark:text-red-200",
    renamed: "bg-blue-100 text-blue-700 dark:bg-blue-950/60 dark:text-blue-200"
  }
  const labels: Record<string, string> = { added: "A", modified: "M", removed: "D", renamed: "R" }

  return <span className={`inline-flex h-5 w-5 shrink-0 items-center justify-center rounded text-[11px] font-semibold ${styles[normalized] || "bg-gray-100 text-gray-600 dark:bg-gray-800 dark:text-gray-300"}`}>{labels[normalized] || normalized.slice(0, 1).toUpperCase()}</span>
}

type SourceTreeFile = JobSourcePayload["tree_items"][number]
type SourceFile = NonNullable<JobSourcePayload["file"]>
type SourceTreeNode = {
  path: string
  name: string
  children: SourceTreeNode[]
  file: SourceTreeFile | null
}

function sourceLanguage(language: SourceFile["language"]): SyntaxLanguage | null {
  const supported: SyntaxLanguage[] = [ "ruby", "javascript", "typescript", "json", "yaml", "shell", "css", "html" ]
  return supported.includes(language as SyntaxLanguage) ? (language as SyntaxLanguage) : null
}

function buildSourceTree(items: SourceTreeFile[]) {
  const root: SourceTreeNode = { path: "", name: "", children: [], file: null }
  const directories = new Map<string, SourceTreeNode>([["", root]])

  for (const item of items) {
    const parts = item.path.split("/").filter(Boolean)
    let parent = root
    let currentPath = ""

    parts.forEach((part, index) => {
      currentPath = currentPath ? `${currentPath}/${part}` : part
      let node = directories.get(currentPath)

      if (!node) {
        node = { path: currentPath, name: part, children: [], file: null }
        directories.set(currentPath, node)
        parent.children.push(node)
      }

      if (index === parts.length - 1) node.file = item
      parent = node
    })
  }

  sortSourceTree(root)
  return root.children
}

function sortSourceTree(node: SourceTreeNode) {
  node.children.sort((a, b) => {
    if (!!a.file !== !!b.file) return a.file ? 1 : -1
    return a.name.localeCompare(b.name)
  })
  node.children.forEach(sortSourceTree)
}

function SourceTreeRow({
  expandedPaths,
  node,
  onSelectPath,
  onToggleDirectory,
  selectedPath
}: {
  expandedPaths: Set<string>
  node: SourceTreeNode
  onSelectPath: (path: string) => void
  onToggleDirectory: (path: string) => void
  selectedPath: string | null
}) {
  return (
    <>
      {node.file ? (
        <button
          className={`block w-full truncate py-1.5 pr-3 text-left font-mono text-xs hover:bg-blue-50 dark:hover:bg-blue-950/40 ${selectedPath === node.path ? "bg-blue-100 text-blue-700 dark:bg-blue-950/60 dark:text-blue-200" : "text-gray-700 dark:text-gray-300"}`}
          key={node.path}
          onClick={() => onSelectPath(node.path)}
          style={{ paddingLeft: `${0.75 + node.path.split("/").length * 0.75}rem` }}
          title={`${node.path} (${formatBytes(node.file.size)})`}
          type="button"
        >
          {node.name}
        </button>
      ) : (
        <button
          aria-expanded={expandedPaths.has(node.path)}
          aria-label={node.name}
          className="block w-full truncate py-1.5 pr-3 text-left font-mono text-xs font-semibold text-gray-700 hover:bg-blue-50 dark:text-gray-300 dark:hover:bg-blue-950/40"
          onClick={() => onToggleDirectory(node.path)}
          style={{ paddingLeft: `${0.75 + Math.max(node.path.split("/").length - 1, 0) * 0.75}rem` }}
          title={node.path}
          type="button"
        >
          <span aria-hidden="true" className={`mr-1 inline-block w-3 text-gray-400 transition-transform dark:text-gray-500 ${expandedPaths.has(node.path) ? "rotate-90" : ""}`}>{">"}</span>
          {node.name}
        </button>
      )}
      {!node.file && expandedPaths.has(node.path) ? node.children.map((child) => (
        <SourceTreeRow
          expandedPaths={expandedPaths}
          key={child.path}
          node={child}
          onSelectPath={onSelectPath}
          onToggleDirectory={onToggleDirectory}
          selectedPath={selectedPath}
        />
      )) : null}
    </>
  )
}

type SourceRefPayload = Pick<JobSourcePayload, "merge_base_sha" | "default_ref" | "branch_commits">

function refOptionsFor(payload: SourceRefPayload, activeRefs: Array<string | null | undefined> = []) {
  const options = new Map<string, string>()
  options.set(payload.merge_base_sha || payload.default_ref, `Merge base (${(payload.merge_base_sha || payload.default_ref).slice(0, 7)})`)
  payload.branch_commits.forEach((commit) => options.set(commit.sha, `${commit.short_sha} ${commit.message}`))
  activeRefs.forEach((ref) => {
    if (ref && !options.has(ref)) options.set(ref, ref.slice(0, 12))
  })

  return Array.from(options, ([value, label]) => ({ value, label }))
}

function sourceSearch(ref: string | null, path: string | null) {
  const params = new URLSearchParams()
  if (ref) params.set("ref", ref)
  if (path) params.set("path", path)
  const value = params.toString()
  return value ? `?${value}` : ""
}

function sourceDiffSearch(baseRef: string | null, headRef: string | null) {
  const params = new URLSearchParams()
  if (baseRef) params.set("base", baseRef)
  if (headRef) params.set("head", headRef)
  const value = params.toString()
  return value ? `?${value}` : ""
}

function withRoutePrefix(path: string, prefix: string) {
  if (!prefix || path.startsWith(prefix)) return path
  if (!path.startsWith("/")) return path

  return `${prefix}${path}`
}


function MergeablePill({ value }: { value: boolean | null }) {
  if (value === true) return <StatusPill state="mergeable" />
  if (value === false) return <StatusPill state="unmergeable" />
  return <StatusPill state="unknown" />
}

function SmallPill({ children }: { children: ReactNode }) {
  return <span className="inline-flex items-center rounded bg-gray-100 px-2 py-0.5 text-xs font-medium text-gray-600 dark:bg-gray-800 dark:text-gray-300">{children}</span>
}

function JobStateBadge({ state }: { state: string }) {
  const normalized = state.toLowerCase()
  const isFail = normalized.includes("fail") || normalized.includes("invalid") || normalized.includes("cancel")
  const isSuccess = normalized.includes("success") || normalized.includes("approved") || normalized.includes("merged") || normalized.includes("closed")
  const isActive = normalized.includes("running") || normalized.includes("queued")

  const colors = isFail
    ? "text-red-700 dark:text-red-300"
    : isSuccess
      ? "text-emerald-700 dark:text-emerald-300"
      : isActive
        ? "text-blue-700 dark:text-blue-300"
        : "text-gray-600 dark:text-gray-300"

  const dotColors = isFail
    ? "bg-red-500 dark:bg-red-400"
    : isSuccess
      ? "bg-emerald-500 dark:bg-emerald-400"
      : isActive
        ? "bg-blue-500 dark:bg-blue-400"
        : "bg-gray-400 dark:bg-gray-500"

  return (
    <span className={`inline-flex items-center gap-1.5 text-sm font-semibold ${colors}`}>
      <span aria-hidden="true" className={`inline-block h-2.5 w-2.5 shrink-0 rounded-full ${dotColors} ${isActive ? "animate-pulse" : ""}`} />
      <span className="capitalize">{state.replaceAll("_", " ")}</span>
    </span>
  )
}

function PanelMessage({ children, tone = "muted" }: { children: ReactNode; tone?: "muted" | "error" | "success" }) {
  const colors = {
    error: "border-red-200 bg-red-50 text-red-700 dark:border-red-900/70 dark:bg-red-950/40 dark:text-red-200",
    success: "border-green-200 bg-green-50 text-green-700 dark:border-green-900/70 dark:bg-green-950/40 dark:text-green-200",
    muted: "border-gray-200 bg-white text-gray-600 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-300"
  }
  return <div className={`rounded border p-4 text-sm ${colors[tone]}`}>{children}</div>
}

function menuButtonClass(tone: ButtonTone) {
  const tones = {
    primary: "text-blue-700 hover:bg-blue-50 dark:text-blue-200 dark:hover:bg-blue-950/40",
    secondary: "text-gray-700 hover:bg-gray-50 dark:text-gray-200 dark:hover:bg-gray-800",
    success: "text-emerald-700 hover:bg-emerald-50 dark:text-emerald-200 dark:hover:bg-emerald-950/40",
    danger: "text-red-700 hover:bg-red-50 dark:text-red-200 dark:hover:bg-red-950/40",
    "danger-outline": "text-red-700 hover:bg-red-50 dark:text-red-200 dark:hover:bg-red-950/40"
  }
  return `block w-full px-4 py-2 text-left text-sm disabled:cursor-not-allowed disabled:opacity-50 ${tones[tone]}`
}

function paginationLinkClass() {
  return "rounded border border-gray-300 px-3 py-1 hover:bg-gray-50 dark:border-gray-700 dark:hover:bg-gray-800"
}

function disabledPaginationClass() {
  return "rounded border border-gray-200 px-3 py-1 text-gray-300 dark:border-gray-800 dark:text-gray-600"
}

function PendingJobTitle({ pending, title }: { pending: boolean; title: string }) {
  const { t } = useT("jobs")
  if (!pending) return <>{title}</>

  return (
    <span className="inline-flex min-w-0 items-center gap-2 italic text-gray-500 dark:text-gray-400">
      <span aria-hidden="true" className="inline-block h-4 w-4 shrink-0 animate-spin rounded-full border-2 border-gray-300 border-t-gray-500 dark:border-gray-700 dark:border-t-gray-300" />
      <span>{t("generating_title")}</span>
    </span>
  )
}

function jobSourceLabel(payload: JobDetailPayload, t: ReturnType<typeof useT>["t"]) {
  if (payload.job.issue_number) return `#${payload.job.issue_number}`
  if (payload.job.kind === "direct") return t("source_label_direct")
  if (payload.job.kind === "cron") return t("source_label_scheduled")
  return jobSlug(payload.job.id)
}

function JobSourceLink({ payload, prefix }: { payload: JobDetailPayload; prefix: string }) {
  const { t } = useT("jobs")
  const label = jobSourceLabel(payload, t)
  if (payload.job.scheduled_task) {
    return (
      <Link className="hover:underline" to={withRoutePrefix(payload.job.scheduled_task.scheduled_task_path, prefix)}>
        {label}
      </Link>
    )
  }
  if (!payload.job.issue_url) return <span>{label}</span>

  return (
    <a className="hover:underline" href={payload.job.issue_url} rel="noopener" target="_blank">
      {label}
    </a>
  )
}

function dependencyLabel(dependency: JobDependency, t: ReturnType<typeof useT>["t"]) {
  if (dependency.pending) return dependency.unresolved_slug || t("dependency_unresolved")
  const target = dependency.depends_on_job
  if (!target) return dependency.unresolved_slug || t("dependency_missing")
  return `${target.repository_slug} ${jobSlug(target.id)} (${target.summary_state})`
}

function DependencyLink({ dependency, prefix }: { dependency: JobDependency; prefix: string }) {
  const { t } = useT("jobs")
  const target = dependency.depends_on_job
  const label = dependencyLabel(dependency, t)
  if (dependency.pending || !target) return <span>{label}</span>

  return <Link className="text-blue-700 underline hover:no-underline" to={withRoutePrefix(target.job_path, prefix)}>{label}</Link>
}

function jobSlug(id: number) {
  return `JOB-${id}`
}

function formatDate(value: string | null) {
  if (!value) return "-"
  return new Intl.DateTimeFormat("en-US", { dateStyle: "medium", timeStyle: "short" }).format(new Date(value))
}

function formatCurrency(value: number) {
  return new Intl.NumberFormat("en-US", { style: "currency", currency: "USD", minimumFractionDigits: 2, maximumFractionDigits: 2 }).format(value)
}

function formatBytes(value: number) {
  if (value < 1024) return `${value} B`
  if (value < 1024 * 1024) return `${(value / 1024).toFixed(1)} KB`
  return `${(value / 1024 / 1024).toFixed(1)} MB`
}

function plural(count: number, singular: string) {
  if (count !== 1 && singular.endsWith("y")) return `${singular.slice(0, -1)}ies`
  return count === 1 ? singular : `${singular}s`
}

type WorkflowStepItem =
  | DisplayStepItem
  | LoopStepItem

type DisplayStepItem =
  | { type: "step"; step: JobStep }
  | GradeStepItem

type GradeStepItem = {
  type: "grade"
  key: string
  steps: JobStep[]
  graders: JobStep[]
}

type LoopStepItem = {
  type: "loop"
  loopId: string
  iterations: Array<{ iteration: number; steps: JobStep[]; items: DisplayStepItem[] }>
}

function workflowStepItems(steps: JobStep[]): WorkflowStepItem[] {
  const items: WorkflowStepItem[] = []
  const consumedLoopIds = new Set<string>()

  for (let index = 0; index < steps.length;) {
    const step = steps[index]
    if (!step.loop_id) {
      const unloopedSteps: JobStep[] = []
      while (index < steps.length && !steps[index].loop_id) {
        unloopedSteps.push(steps[index])
        index += 1
      }
      items.push(...displayStepItems(unloopedSteps))
      continue
    }

    index += 1
    if (consumedLoopIds.has(step.loop_id)) continue
    consumedLoopIds.add(step.loop_id)

    const loopSteps = steps.filter((candidate) => candidate.loop_id === step.loop_id)
    const iterations = loopIterations(loopSteps)
    if (iterations.length <= 1) {
      items.push(...displayStepItems(loopSteps))
      continue
    }

    items.push({ type: "loop", loopId: step.loop_id, iterations })
  }

  return items
}

function displayStepItems(steps: JobStep[]): DisplayStepItem[] {
  const items: DisplayStepItem[] = []
  const sortedSteps = [...steps].sort((left, right) => left.position - right.position)

  for (let index = 0; index < sortedSteps.length;) {
    const step = sortedSteps[index]
    if (!isGradeDisplayStep(step)) {
      items.push({ type: "step", step })
      index += 1
      continue
    }

    const gradeSteps: JobStep[] = []
    while (index < sortedSteps.length && isGradeDisplayStep(sortedSteps[index])) {
      gradeSteps.push(sortedSteps[index])
      index += 1
    }
    items.push({
      type: "grade",
      key: `grade-${gradeSteps.map((gradeStep) => gradeStep.id).join("-")}`,
      steps: gradeSteps,
      graders: gradeSteps.filter((gradeStep) => gradeStep.kind === "grader" || gradeStep.kind === "grade")
    })
  }

  return items
}

function loopIterations(steps: JobStep[]) {
  const groups = new Map<number, JobStep[]>()
  steps.forEach((step) => {
    const iteration = step.iteration ?? 1
    groups.set(iteration, [...(groups.get(iteration) ?? []), step])
  })

  return Array.from(groups.entries())
    .sort(([left], [right]) => left - right)
    .map(([iteration, iterationSteps]) => ({
      iteration,
      steps: iterationSteps.sort((left, right) => left.position - right.position),
      items: displayStepItems(iterationSteps)
    }))
}

function isGradeDisplayStep(step: JobStep) {
  return step.kind === "grader_fanout" || step.kind === "grader" || step.kind === "grader_collect" || step.kind === "grade"
}

function displayStepItemKey(item: DisplayStepItem) {
  return item.type === "grade" ? item.key : `step-${item.step.id}`
}

function gradePhases(item: GradeStepItem, t: ReturnType<typeof useT>["t"]) {
  return item.steps.map((step) => {
    if (step.kind === "grader_fanout") return { step, displayName: t("grade_setup"), metadataLabel: "grade setup" }
    if (step.kind === "grader_collect") return { step, displayName: t("grade_result"), metadataLabel: "grade result" }
    if (step.kind === "grade") return { step, displayName: step.display_name || t("grade_label"), metadataLabel: "grade" }
    return { step, displayName: step.display_name, metadataLabel: "grader" }
  })
}

function gradeDisplayStatus(item: GradeStepItem) {
  const statuses = item.steps.map((step) => effectiveStepStatus(step)).filter((status): status is string => Boolean(status))
  if (statuses.includes("running")) return "running"
  if (statuses.includes("queued")) return "queued"
  if (statuses.includes("failed")) return "failed"
  if (statuses.includes("cancelled")) return "cancelled"
  if (item.steps.length > 0 && item.steps.every((step) => effectiveStepStatus(step) === "succeeded")) return "succeeded"
  return null
}

function gradeSummaries(item: GradeStepItem): GradeSummary[] {
  return item.graders.map((step) => {
    const details = objectDetails(step.details)
    const status = gradeSummaryStatus(step, details)
    return {
      name: stringValue(details.name) || step.display_name || "grader",
      status,
      required: booleanValue(details.required),
      exitCode: numberValue(details.exit_code),
      duration: numberValue(details.duration_s),
      logBytes: numberValue(details.log_bytes)
    }
  })
}

function gradeSummaryStatus(step: JobStep, details: Record<string, unknown>): GradeSummary["status"] {
  const status = stringValue(details.status)
  if (status === "passed" || status === "failed" || status === "error" || status === "cancelled") return status
  if (step.state === "succeeded") return "passed"
  if (step.state === "failed") return numberValue(details.exit_code) === null ? "error" : "failed"
  if (step.state === "running") return "running"
  if (step.state === "queued") return "queued"
  if (step.state === "cancelled") return "cancelled"
  return "unknown"
}

function gradeSummaryCounts(summaries: GradeSummary[]) {
  return summaries.reduce((counts, summary) => {
    if (summary.status === "passed") counts.passed += 1
    else if (summary.status === "failed") counts.failed += 1
    else if (summary.status === "error") counts.error += 1
    return counts
  }, { passed: 0, failed: 0, error: 0 })
}

function loopDisplayName(item: LoopStepItem, t: ReturnType<typeof useT>["t"]) {
  const kinds = item.iterations.flatMap((iteration) => iteration.steps.map((step) => step.kind))
  if (kinds.some((kind) => kind === "grade" || kind === "grader" || kind.startsWith("grader_"))) return t("loop_grade_name")
  return t("loop_name")
}

function loopDisplayStatus(item: LoopStepItem) {
  const latestIteration = item.iterations[item.iterations.length - 1]
  if (!latestIteration) return null

  const statuses = latestIteration.steps.map((step) => effectiveLoopStepStatus(step))
  if (statuses.includes("running")) return "running"
  if (statuses.includes("queued")) return "queued"
  if (statuses.includes("failed")) return "failed"
  if (statuses.includes("cancelled")) return "cancelled"
  if (statuses.length > 0 && statuses.every((status) => status === "succeeded")) return "succeeded"
  return null
}

function effectiveStepStatus(step: JobStep) {
  const activeRun = sortedRunsNewestFirst(step.runs).find((run) => isActiveState(run.state))
  return activeRun?.state ?? step.display_status
}

function effectiveLoopStepStatus(step: JobStep) {
  return effectiveStepStatus(step) ?? step.state
}

function sortedRunsNewestFirst(runs: JobRun[]) {
  return [...runs].sort((left, right) => {
    const leftTime = runSortTime(left)
    const rightTime = runSortTime(right)
    if (leftTime !== rightTime) return rightTime - leftTime
    return right.id - left.id
  })
}

function runSortTime(run: JobRun) {
  return new Date(run.started_at || run.created_at || run.updated_at || 0).getTime()
}

function isActiveState(state: string) {
  return state === "queued" || state === "running"
}

// Live wall-clock, ticking every second while `active`. Used so a
// queued/running Run's elapsed time updates in place.
function useNow(active: boolean) {
  const [now, setNow] = useState(() => Date.now())
  useEffect(() => {
    if (!active) return undefined
    const id = window.setInterval(() => setNow(Date.now()), 1000)
    return () => window.clearInterval(id)
  }, [active])
  return now
}

function formatElapsed(seconds: number) {
  const total = Math.max(0, Math.floor(seconds))
  if (total < 60) return `${total}s`
  const minutes = Math.floor(total / 60)
  if (minutes < 60) return `${minutes}m ${total % 60}s`
  const hours = Math.floor(minutes / 60)
  return `${hours}h ${minutes % 60}m`
}

// A queued Run hasn't started_at yet — it's waiting for a free worker in
// the SolidQueue pool, NOT "starting the agent". Surface that honestly
// (with how long it's been waiting) so a capacity wait doesn't read as a
// hung job; a running Run shows how long it's been going.
function ActiveRunBanner({ run }: { run: JobRun }) {
  const { t } = useT("jobs")
  const location = useLocation()
  const prefix = location.pathname.startsWith("/app-shell") ? "/app-shell" : ""
  const queued = run.state === "queued" || !run.started_at
  const now = useNow(true)
  const sinceIso = queued ? run.created_at : run.started_at
  const elapsed = sinceIso ? formatElapsed((now - new Date(sinceIso).getTime()) / 1000) : null

  if (queued) {
    return (
      <div className="mt-2 rounded border border-amber-200 bg-amber-50 px-3 py-2 text-xs text-amber-900 dark:border-amber-900/70 dark:bg-amber-950/40 dark:text-amber-200">
        <span className="font-semibold">{t("run_queued_waiting", { id: run.id })}{elapsed ? ` · ${t("run_queued_suffix", { elapsed })}` : ""}</span>
        <span className="mt-1 block text-amber-700 dark:text-amber-300">
          {t("run_queued_backlog")}{" "}
          <Link className="underline hover:text-amber-900 dark:hover:text-amber-100" to={withRoutePrefix("/admin/queue/pending", prefix)}>{t("run_queued_backlog_link")}</Link> {t("run_queued_backlog_suffix")}
        </span>
      </div>
    )
  }

  return (
    <div className="mt-2 rounded border border-blue-200 bg-blue-50 px-3 py-2 text-xs text-blue-800 dark:border-blue-900/70 dark:bg-blue-950/40 dark:text-blue-200">
      <span className="font-semibold">{t("run_running", { id: run.id })}{elapsed ? ` · ${elapsed}` : ""}</span>
      <span> {t("run_running_suffix", { date: formatDate(run.started_at) })}</span>
    </div>
  )
}

function prepareFailureDetails(step: JobStep): PrepareFailure | null {
  if (step.kind !== "prepare" || !isRecord(step.details)) return null
  const failure = step.details.prepare_failure
  return isRecord(failure) ? failure as PrepareFailure : null
}

function prepareFailureStatus(failure: PrepareFailure, t: ReturnType<typeof useT>["t"]) {
  if (failure.timed_out) return t("prepare_failure_timed_out")
  if (failure.operator_killed) return t("prepare_failure_operator_killed")
  if (failure.stopped) return t("prepare_failure_stopped")
  if (failure.aliveness_failed) return t("prepare_failure_aliveness_failed")
  if (failure.exit_status != null) return t("prepare_failure_exit", { code: failure.exit_status })
  return t("prepare_failure_failed")
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value)
}

function stringify(value: unknown) {
  return typeof value === "string" ? value : JSON.stringify(value, null, 2)
}

function humanize(value: string) {
  return value.replaceAll("_", " ")
}

function objectDetails(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) return {}
  return value as Record<string, unknown>
}

function stringValue(value: unknown) {
  return typeof value === "string" ? value : null
}

function numberValue(value: unknown) {
  if (typeof value === "number" && Number.isFinite(value)) return value
  if (typeof value === "string" && value.trim() !== "") {
    const parsed = Number(value)
    return Number.isFinite(parsed) ? parsed : null
  }
  return null
}

function booleanValue(value: unknown) {
  return typeof value === "boolean" ? value : null
}

function errorMessage(error: Error, fallback: string) {
  return error instanceof ApiError ? error.message : fallback
}
